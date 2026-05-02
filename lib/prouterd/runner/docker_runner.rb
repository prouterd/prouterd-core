require "docker"
require "json"
require "fileutils"
require "tmpdir"
require "timeout"
require "digest"
require "shellwords"
require "time"

module Prouterd
  module Runner
    # Runs a single block as a Docker container.
    #
    # Contract honored here (spec §10):
    #
    #   * /prouter/input.json   pre-populated by the runner before container start
    #   * /prouter/output.json  read by the runner after container exit (REQUIRED)
    #   * /prouter/artifacts/   writable directory; runner archives anything inside
    #   * env PROUTER_RUN_ID, PROUTER_PROCESS_NAME, PROUTER_BLOCK_NAME,
    #         PROUTER_ATTEMPT, PROUTER_INPUT_PATH, PROUTER_OUTPUT_PATH,
    #         PROUTER_ARTIFACTS_DIR, plus resolved secrets
    #   * exit_code 0 + valid output.json => success; anything else => failure
    #     with classified error_type (missing_output, invalid_output, timeout, ...)
    class DockerRunner
      WORK_DIR_PREFIX = "prouterd-step-".freeze
      INPUT_FILENAME = "input.json".freeze
      OUTPUT_FILENAME = "output.json".freeze
      ARTIFACTS_DIRNAME = "artifacts".freeze

      def run(request)
        work_dir = Dir.mktmpdir(WORK_DIR_PREFIX)
        prepare_work_dir(work_dir, request.input_json)

        container = create_container(request, work_dir)
        started_at = Time.now.utc
        container.start

        error_type = nil
        error_message = nil
        exit_code = nil

        begin
          if request.timeout_ms
            wait_with_timeout(container, request.timeout_ms / 1000.0)
          else
            container.wait
          end
          state = container.json["State"] || {}
          exit_code = state["ExitCode"]
        rescue Timeout::Error
          force_stop(container)
          error_type = "timeout"
          error_message = "block exceeded timeout of #{request.timeout_ms}ms"
        end

        finished_at = Time.now.utc

        stdout, stderr = capture_logs(container)

        output_json = nil
        if error_type.nil?
          error_type, error_message, output_json = classify_outcome(work_dir, exit_code)
        end

        artifacts = collect_artifacts(work_dir)

        ExecutionResult.new(
          exit_code: exit_code,
          stdout: stdout,
          stderr: stderr,
          output_json: output_json,
          artifacts: artifacts,
          error_type: error_type,
          error_message: error_message,
          duration_ms: ((finished_at - started_at) * 1000).to_i,
          started_at: started_at.iso8601(3),
          finished_at: finished_at.iso8601(3)
        )
      rescue Docker::Error::DockerError => e
        ExecutionResult.new(
          exit_code: nil,
          stdout: nil,
          stderr: nil,
          output_json: nil,
          artifacts: [],
          error_type: "docker_error",
          error_message: e.message,
          duration_ms: 0,
          started_at: started_at&.iso8601(3),
          finished_at: Time.now.utc.iso8601(3)
        )
      ensure
        cleanup(container, work_dir)
      end

      private

      def prepare_work_dir(dir, input_json)
        File.write(File.join(dir, INPUT_FILENAME), JSON.dump(input_json || {}))
        FileUtils.mkdir_p(File.join(dir, ARTIFACTS_DIRNAME))
        # Ensure the directory is world-writable so containers running as
        # non-root users can create output.json. World-perms are acceptable
        # here because the dir lives in the host's /tmp and has a unique name.
        File.chmod(0o777, dir)
        File.chmod(0o777, File.join(dir, ARTIFACTS_DIRNAME))
      end

      def create_container(request, work_dir)
        cmd = parse_command(request.command)
        env = build_env(request)
        host_config = {
          "Binds" => ["#{work_dir}:/prouter:rw"],
          "NetworkMode" => network_mode(request.network),
          "AutoRemove" => false
        }

        params = {
          "Image" => request.image,
          "Env" => env.map { |k, v| "#{k}=#{v}" },
          "WorkingDir" => "/prouter",
          "HostConfig" => host_config,
          "Tty" => false,
          "OpenStdin" => false,
          "Labels" => {
            "prouterd.run_uid" => request.run_uid.to_s,
            "prouterd.process" => request.process_name.to_s,
            "prouterd.block"   => request.block_name.to_s
          }
        }
        params["Cmd"] = cmd if cmd

        Docker::Container.create(params)
      end

      def parse_command(command)
        return nil if command.nil? || command.empty?

        Shellwords.split(command)
      rescue ArgumentError
        # Fallback: pass through as a single sh -c invocation.
        ["sh", "-c", command]
      end

      def build_env(request)
        # The orchestrator owns the PROUTER_* contract — runner just forwards.
        request.env || {}
      end

      def network_mode(network)
        network == "off" ? "none" : "bridge"
      end

      def wait_with_timeout(container, seconds)
        Timeout.timeout(seconds) { container.wait }
      end

      def force_stop(container)
        container.kill rescue nil
      end

      def capture_logs(container)
        # docker-api returns multiplexed log frames for non-TTY containers;
        # demuxing here is more reliable than relying on the gem's filtering.
        raw = container.logs(stdout: true, stderr: true, tail: "all")
        demultiplex_logs(raw)
      rescue Docker::Error::DockerError
        ["", ""]
      end

      def demultiplex_logs(raw)
        return ["", ""] if raw.nil? || raw.empty?

        raw = raw.b # binary
        out = String.new(encoding: "UTF-8")
        err = String.new(encoding: "UTF-8")
        pos = 0
        len = raw.bytesize

        while pos + 8 <= len
          stream = raw.getbyte(pos)
          size = raw.byteslice(pos + 4, 4).unpack1("N")
          payload = raw.byteslice(pos + 8, size)
          break if payload.nil?

          payload_str = payload.dup.force_encoding("UTF-8")
          payload_str.scrub!("?")
          case stream
          when 1 then out << payload_str
          when 2 then err << payload_str
          else
            # Unknown stream byte often means the daemon is returning raw
            # un-multiplexed output (TTY-mode). Treat the whole buffer as stdout.
            return [raw.force_encoding("UTF-8").scrub("?"), ""]
          end
          pos += 8 + size
        end

        [out, err]
      end

      def classify_outcome(work_dir, exit_code)
        output_path = File.join(work_dir, OUTPUT_FILENAME)
        if exit_code != 0
          return ["non_zero_exit", "block exited with code #{exit_code}", nil]
        end
        unless File.exist?(output_path)
          return ["missing_output", "block did not write /prouter/#{OUTPUT_FILENAME}", nil]
        end

        raw = File.read(output_path)
        if raw.empty?
          return ["invalid_output", "/prouter/#{OUTPUT_FILENAME} is empty", nil]
        end
        begin
          json = JSON.parse(raw)
          [nil, nil, json]
        rescue JSON::ParserError => e
          ["invalid_output", "output.json is not valid JSON: #{e.message}", nil]
        end
      end

      def collect_artifacts(work_dir)
        dir = File.join(work_dir, ARTIFACTS_DIRNAME)
        return [] unless File.directory?(dir)

        descriptors = []
        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next unless File.file?(path)

          rel_name = path.sub(/\A#{Regexp.escape(dir)}\/?/, "")
          next if rel_name.empty?

          size = File.size(path)
          checksum = file_checksum(path)
          descriptors << ArtifactDescriptor.new(
            name: rel_name,
            host_path: path,
            size_bytes: size,
            content_type: nil,
            checksum: checksum
          )
        end
        descriptors
      end

      def file_checksum(path)
        digest = Digest::SHA256.new
        File.open(path, "rb") do |f|
          while (chunk = f.read(64 * 1024))
            digest.update(chunk)
          end
        end
        digest.hexdigest
      end

      def cleanup(container, work_dir)
        if container
          begin
            container.delete(force: true)
          rescue Docker::Error::DockerError, StandardError
            # best-effort cleanup; daemon may have already pruned it
          end
        end
        FileUtils.remove_entry(work_dir) if work_dir && File.directory?(work_dir)
      end
    end
  end
end
