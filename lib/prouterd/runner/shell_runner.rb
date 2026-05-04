require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "timeout"
require "digest"
require "shellwords"
require "time"

module Prouterd
  module Runner
    # Local-process runner for `block ... type shell ... exec "..."`.
    #
    # Honors the same /prouter/{input.json,output.json,artifacts/} contract
    # as DockerRunner — we just exec a process on the host instead of
    # spinning up a container. The orchestrator dispatches to either runner
    # purely based on block.execution_type, so all downstream code (logs,
    # artifacts, retries, replay, redaction) is identical.
    #
    # Shell blocks are LESS isolated than Docker. The block runs
    # under the daemon's user, sees the daemon's filesystem (modulo `cwd`),
    # and shares the daemon's network. Operators are expected to use shell
    # blocks for trusted code on the same host as the daemon — not for
    # multi-tenant or untrusted-code scenarios.
    class ShellRunner
      WORK_DIR_PREFIX = "prouterd-shell-".freeze
      INPUT_FILENAME = "input.json".freeze
      OUTPUT_FILENAME = "output.json".freeze
      ARTIFACTS_DIRNAME = "artifacts".freeze
      INPUTS_DIRNAME = "inputs".freeze

      def run(request)
        work_dir = Dir.mktmpdir(WORK_DIR_PREFIX)
        prepare_work_dir(work_dir, request.input_json)
        stage_inputs(work_dir, request.staged_inputs)

        cmd = parse_command(request.field("exec"), request.field("shell"))
        env = build_env(request, work_dir)
        cwd = request.field("cwd") || Dir.pwd

        unless File.directory?(cwd)
          return error_result("invalid_cwd", "shell cwd does not exist: #{cwd}")
        end

        started_at = Time.now.utc
        stdout_str = ""
        stderr_str = ""
        exit_code = nil
        error_type = nil
        error_message = nil

        begin
          if request.timeout_ms
            Timeout.timeout(request.timeout_ms / 1000.0) do
              stdout_str, stderr_str, status = Open3.capture3(env, *cmd, chdir: cwd)
              exit_code = status.exitstatus
            end
          else
            stdout_str, stderr_str, status = Open3.capture3(env, *cmd, chdir: cwd)
            exit_code = status.exitstatus
          end
        rescue Timeout::Error
          error_type = "timeout"
          error_message = "shell exec exceeded timeout of #{request.timeout_ms}ms"
        rescue Errno::ENOENT => e
          error_type = "shell_error"
          error_message = e.message
        end

        finished_at = Time.now.utc

        output_json = nil
        if error_type.nil?
          error_type, error_message, output_json = classify_outcome(work_dir, exit_code)
        end

        artifacts = collect_artifacts(work_dir)

        ExecutionResult.new(
          exit_code: exit_code,
          stdout: stdout_str,
          stderr: stderr_str,
          output_json: output_json,
          artifacts: artifacts,
          error_type: error_type,
          error_message: error_message,
          duration_ms: ((finished_at - started_at) * 1000).to_i,
          started_at: started_at.iso8601(3),
          finished_at: finished_at.iso8601(3)
        )
      ensure
        FileUtils.remove_entry(work_dir) if work_dir && File.directory?(work_dir)
      end

      private

      def prepare_work_dir(dir, input_json)
        File.write(File.join(dir, INPUT_FILENAME), JSON.dump(input_json || {}))
        FileUtils.mkdir_p(File.join(dir, ARTIFACTS_DIRNAME))
      end

      def parse_command(command, shell_path)
        shell = shell_path || "/bin/sh"
        return [shell, "-c", "true"] if command.nil? || command.empty?

        Shellwords.split(command)
      rescue ArgumentError
        [shell, "-c", command]
      end

      def build_env(request, work_dir)
        env = (request.env || {}).dup
        # Per-block env declared via `env KEY VALUE` in the shell type
        # section. Merged AFTER PROUTER_* so users can intentionally override.
        if (custom = request.field("env")).is_a?(Hash)
          env.merge!(custom)
        end
        # Override the daemon's PROUTER_* (Docker uses /prouter mount; shell
        # uses the actual host path). The orchestrator-built env values that
        # reference /prouter/... need to be redirected to work_dir.
        env["PROUTER_INPUT_PATH"]    = File.join(work_dir, INPUT_FILENAME)
        env["PROUTER_OUTPUT_PATH"]   = File.join(work_dir, OUTPUT_FILENAME)
        env["PROUTER_ARTIFACTS_DIR"] = File.join(work_dir, ARTIFACTS_DIRNAME)
        env["PROUTER_WORKDIR"]       = work_dir
        # Same redirection for staged-artifact env vars: the orchestrator
        # sets PROUTER_INPUT_<NAME>=/prouter/inputs/<name> for the docker
        # mount; rewrite to the host-side staging directory.
        (request.staged_inputs || {}).each_key do |local_name|
          env["PROUTER_INPUT_#{local_name.upcase}"] = File.join(work_dir, INPUTS_DIRNAME, local_name)
        end
        env
      end

      def stage_inputs(work_dir, staged)
        return if staged.nil? || staged.empty?

        inputs_dir = File.join(work_dir, INPUTS_DIRNAME)
        FileUtils.mkdir_p(inputs_dir)
        staged.each do |local_name, src_path|
          FileUtils.cp(src_path, File.join(inputs_dir, local_name))
        end
      end

      def classify_outcome(work_dir, exit_code)
        path = File.join(work_dir, OUTPUT_FILENAME)
        if exit_code != 0
          return ["non_zero_exit", "shell exited with code #{exit_code}", nil]
        end
        unless File.exist?(path)
          return ["missing_output", "shell did not write #{OUTPUT_FILENAME}", nil]
        end
        raw = File.read(path)
        return ["invalid_output", "#{OUTPUT_FILENAME} is empty", nil] if raw.empty?

        begin
          [nil, nil, JSON.parse(raw)]
        rescue JSON::ParserError => e
          ["invalid_output", "output.json is not valid JSON: #{e.message}", nil]
        end
      end

      def collect_artifacts(work_dir)
        dir = File.join(work_dir, ARTIFACTS_DIRNAME)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
          next unless File.file?(path)

          rel = path.sub(/\A#{Regexp.escape(dir)}\/?/, "")
          next if rel.empty?

          ArtifactDescriptor.new(
            name: rel,
            host_path: path,
            size_bytes: File.size(path),
            content_type: nil,
            checksum: file_checksum(path)
          )
        end
      end

      def file_checksum(path)
        d = Digest::SHA256.new
        File.open(path, "rb") { |f| while (chunk = f.read(64 * 1024)); d.update(chunk); end }
        d.hexdigest
      end

      def error_result(type, message)
        ExecutionResult.new(
          exit_code: nil, stdout: "", stderr: "",
          output_json: nil, artifacts: [],
          error_type: type, error_message: message,
          duration_ms: 0, started_at: nil, finished_at: nil
        )
      end
    end
  end
end
