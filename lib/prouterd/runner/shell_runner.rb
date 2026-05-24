# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "digest"
require "shellwords"
require "time"
require_relative "io_limits"

module Prouterd
  module Runner
    # Local-process runner for `block ... interface shell ... exec "..."`.
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
          stdout_str, stderr_str, exit_code, timed_out = capture_command(
            env, cmd, cwd: cwd, timeout_ms: request.timeout_ms
          )
          if timed_out
            error_type = "timeout"
            error_message = "shell exec exceeded timeout of #{request.timeout_ms}ms"
          end
        rescue Errno::ENOENT => e
          error_type = "shell_error"
          error_message = e.message
        end

        finished_at = Time.now.utc

        output_json = nil
        if error_type.nil?
          error_type, error_message, output_json = classify_outcome(work_dir, exit_code, stdout_str)
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
        # Per-block env declared via `env KEY VALUE` in the shell interface
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

      def capture_command(env, cmd, cwd:, timeout_ms:)
        timeout_seconds = timeout_ms && (timeout_ms / 1000.0)
        Open3.popen3(env, *cmd, chdir: cwd) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_reader = stream_reader(stdout)
          err_reader = stream_reader(stderr)
          timed_out = false
          status = nil
          deadline = timeout_seconds && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds)

          loop do
            if wait_thr.join(0.05)
              status = wait_thr.value
              break
            end

            next unless deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            timed_out = true
            terminate_process(wait_thr)
            status = wait_thr.value if wait_thr.join(0)
            break
          end

          out_reader.join
          err_reader.join
          [out_reader.value, err_reader.value, timed_out ? nil : status&.exitstatus, timed_out]
        end
      end

      def stream_reader(io)
        Thread.new do
          IOLimits.read_stream(io)
        end
      end

      def terminate_process(wait_thr)
        pid = wait_thr.pid
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          return
        end

        return if wait_thr.join(1)

        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      ensure
        wait_thr.join
      end

      def classify_outcome(work_dir, exit_code, stdout_str)
        path = File.join(work_dir, OUTPUT_FILENAME)
        if exit_code != 0
          # Preserve any structured output the failing block managed to
          # emit before bailing — operator can inspect it via `show run`/
          # `show logs`. Downstream context propagation is gated on
          # success in BlockExecutor, so this only affects the persisted
          # step row; failed blocks still don't seed downstream
          # templating with junk.
          return ["non_zero_exit", "shell exited with code #{exit_code}",
                  extract_partial_output(work_dir, stdout_str)]
        end

        # If the block explicitly wrote /prouter/output.json, that always
        # wins (mirrors the docker contract).
        if File.exist?(path)
          ok, raw, too_large = read_output_file(path)
          return ["output_too_large", too_large, nil] unless ok
          return [nil, nil, {}] if raw.empty?

          begin
            return [nil, nil, JSON.parse(raw)]
          rescue JSON::ParserError => e
            return ["invalid_output", "output.json is not valid JSON: #{e.message}", nil]
          end
        end

        # No output.json. If stdout is JSON-only, treat stdout as the
        # block's output — `exec \`echo '{"score":85}'\`` becomes a clean
        # one-liner. If stdout is empty or non-JSON (e.g. log lines), fall
        # through to {} so the side-effect-only case stays valid.
        trimmed = stdout_str.to_s.strip
        unless trimmed.empty?
          begin
            parsed = JSON.parse(trimmed)
            return [nil, nil, parsed] if parsed.is_a?(Hash) || parsed.is_a?(Array)
          rescue JSON::ParserError
            # not JSON — pure log output, fall through
          end
        end

        [nil, nil, {}]
      end

      # Best-effort recovery of a structured payload from a failed run.
      # Returns nil when neither output.json nor stdout yield a Hash/Array
      # — the step still persists with output_json=nil and the operator
      # falls back to the captured stdout/stderr log streams.
      def extract_partial_output(work_dir, stdout_str)
        path = File.join(work_dir, OUTPUT_FILENAME)
        if File.exist?(path)
          ok, raw, = read_output_file(path)
          return nil unless ok

          raw = raw.to_s
          unless raw.empty?
            parsed = (JSON.parse(raw) rescue nil)
            return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
          end
        end
        trimmed = stdout_str.to_s.strip
        return nil if trimmed.empty?

        parsed = (JSON.parse(trimmed) rescue nil)
        return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

        nil
      end

      def collect_artifacts(work_dir)
        dir = File.join(work_dir, ARTIFACTS_DIRNAME)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
          stat = File.lstat(path)
          next unless stat.file?

          rel = path.sub(/\A#{Regexp.escape(dir)}\/?/, "")
          next if rel.empty?

          ArtifactDescriptor.new(
            name: rel,
            host_path: path,
            size_bytes: stat.size,
            content_type: nil,
            checksum: file_checksum(path)
          )
        rescue SystemCallError
          nil
        end
      end

      def file_checksum(path)
        d = Digest::SHA256.new
        File.open(path, "rb") { |f| while (chunk = f.read(64 * 1024)); d.update(chunk); end }
        d.hexdigest
      end

      def read_output_file(path)
        IOLimits.read_file(path)
      rescue SystemCallError => e
        [false, nil, e.message]
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
