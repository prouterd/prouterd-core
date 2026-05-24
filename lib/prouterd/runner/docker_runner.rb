# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "timeout"
require "digest"
require "shellwords"
require "time"
require_relative "docker_stop"

module Prouterd
  module Runner
    # Runs a single block as a Docker container.
    #
    # The `docker-api` gem is an OPTIONAL dependency — installs that don't
    # use `interface docker` don't need it. When a block tries to dispatch
    # through DockerRunner without docker-api installed, the runner returns
    # a clean error_type:"missing_dependency" result instead of crashing
    # at parse time.
    #
    # Contract honored here:
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
      INPUTS_DIRNAME = "inputs".freeze

      # Lazy-loaded once per process. Returns true iff `docker-api` is
      # installed and importable. Called from `run` so the gem is only
      # touched on the first dispatch through DockerRunner.
      def self.docker_available?
        return @docker_available unless @docker_available.nil?

        @docker_available = begin
          require "docker"
          true
        rescue LoadError
          false
        end
      end

      def initialize(in_flight: nil)
        @in_flight = in_flight
      end

      def run(request)
        unless self.class.docker_available?
          return ExecutionResult.new(
            exit_code: nil, stdout: "", stderr: "",
            output_json: nil, artifacts: [],
            error_type: "missing_dependency",
            error_message: "interface docker requires the 'docker-api' gem (gem install docker-api)",
            duration_ms: 0, started_at: nil, finished_at: nil
          )
        end
        work_dir = Dir.mktmpdir(WORK_DIR_PREFIX)
        prepare_work_dir(work_dir, request.input_json)
        stage_inputs(work_dir, request.staged_inputs)

        ensure_image(request)
        container = create_container(request, work_dir)
        started_at = Time.now.utc
        container.start
        @in_flight&.attach_container(request.run_uid, container.id)

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
          error_type, error_message, output_json = classify_outcome(work_dir, exit_code, stdout)
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
        @in_flight&.detach_container(request.run_uid, container.id) if container
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

      # Copy each archived artifact into <work_dir>/inputs/<local_name>. The
      # bind mount of work_dir as /prouter exposes them at /prouter/inputs/*
      # inside the container; the orchestrator already set
      # PROUTER_INPUT_<local_name> env vars pointing at those paths.
      def stage_inputs(work_dir, staged)
        return if staged.nil? || staged.empty?

        inputs_dir = File.join(work_dir, INPUTS_DIRNAME)
        FileUtils.mkdir_p(inputs_dir)
        staged.each do |local_name, src_path|
          FileUtils.cp(src_path, File.join(inputs_dir, local_name))
        end
        File.chmod(0o755, inputs_dir)
      end

      def create_container(request, work_dir)
        cmd = parse_command(request.field("command"))
        env = build_env(request)
        host_config = {
          "Binds" => ["#{work_dir}:/prouter:rw"],
          "NetworkMode" => network_mode(request.field("network")),
          "AutoRemove" => false
        }
        if (mem_bytes = parse_memory(request.field("memory")))
          host_config["Memory"] = mem_bytes
        end
        if (nano_cpus = parse_cpu(request.field("cpu")))
          host_config["NanoCpus"] = nano_cpus
        end

        params = {
          "Image" => request.field("image"),
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
        user = request.field("user")
        params["User"] = user if user && !user.empty?

        Docker::Container.create(params)
      end

      # Honor the block's pull policy before the container is created, so
      # `pull always` re-fetches and `pull never` errors loud instead of
      # racing with a missing image. `if-missing` (the default) only pulls
      # when the image isn't present locally.
      def ensure_image(request)
        policy = request.field("pull") || "if-missing"
        return if policy == "never"

        image = request.field("image")
        return if policy == "if-missing" && image_present?(image)

        Docker::Image.create("fromImage" => image)
      end

      def image_present?(reference)
        Docker::Image.get(reference)
        true
      rescue Docker::Error::NotFoundError
        false
      end

      # Accepts "512m" / "1g" / "2GB" / raw bytes ("104857600"). Returns
      # an Integer byte count, or nil if the input is blank/unparseable —
      # callers fall back to "no limit".
      def parse_memory(value)
        return nil if value.nil? || value.to_s.strip.empty?

        s = value.to_s.strip.downcase
        if (m = s.match(/\A(\d+(?:\.\d+)?)\s*([kmgt]?)b?\z/))
          num = m[1].to_f
          mult = case m[2]
                 when "k" then 1024
                 when "m" then 1024**2
                 when "g" then 1024**3
                 when "t" then 1024**4
                 else 1
                 end
          (num * mult).to_i
        end
      end

      # Accepts "0.5" / "2" / "2.5". Returns Docker's NanoCpus integer
      # (CPUs * 1e9), or nil for blank/unparseable.
      def parse_cpu(value)
        return nil if value.nil? || value.to_s.strip.empty?

        f = Float(value.to_s.strip)
        return nil unless f.positive?

        (f * 1_000_000_000).to_i
      rescue ArgumentError, TypeError
        nil
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

      # Two-stage stop is shared with Recovery's orphan-container kill
      # and v1.rb's cancel handler — extracted into Runner::DockerStop.
      def force_stop(container)
        Runner::DockerStop.force_stop(container)
      end

      # Per-stream cap to keep a misbehaving block from OOM-ing the daemon.
      # Override via PROUTERD_LOG_CAPTURE_BYTES (per stream). The block can
      # still write more — it'll show up in `docker logs` directly — but
      # what we persist into run_logs is bounded.
      DEFAULT_LOG_CAPTURE_BYTES = 1 * 1024 * 1024

      def capture_logs(container)
        cap = (ENV["PROUTERD_LOG_CAPTURE_BYTES"] || DEFAULT_LOG_CAPTURE_BYTES).to_i
        # docker-api returns multiplexed log frames for non-TTY containers;
        # we demux ourselves and clamp each side to `cap` bytes so a 5GB
        # stdout can't allocate a 5GB Ruby string.
        raw = container.logs(stdout: true, stderr: true, tail: "all")
        demultiplex_logs(raw, cap: cap)
      rescue Docker::Error::DockerError
        ["", ""]
      end

      def demultiplex_logs(raw, cap: DEFAULT_LOG_CAPTURE_BYTES)
        return ["", ""] if raw.nil? || raw.empty?

        raw = raw.b # binary
        out = String.new(encoding: "UTF-8")
        err = String.new(encoding: "UTF-8")
        pos = 0
        len = raw.bytesize
        out_truncated = false
        err_truncated = false

        while pos + 8 <= len
          stream = raw.getbyte(pos)
          size = raw.byteslice(pos + 4, 4).unpack1("N")
          payload = raw.byteslice(pos + 8, size)
          break if payload.nil?

          payload_str = payload.dup.force_encoding("UTF-8")
          payload_str.scrub!("?")
          case stream
          when 1 then out_truncated ||= !append_capped(out, payload_str, cap)
          when 2 then err_truncated ||= !append_capped(err, payload_str, cap)
          else
            # Unknown stream byte often means the daemon is returning raw
            # un-multiplexed output (TTY-mode). Treat the whole buffer as
            # stdout and apply the same cap.
            buf = raw.force_encoding("UTF-8").scrub("?")
            buf = "#{buf[0, cap]}\n…[truncated to #{cap} bytes]" if buf.bytesize > cap
            return [buf, ""]
          end
          pos += 8 + size
        end

        out << "\n…[truncated to #{cap} bytes]" if out_truncated
        err << "\n…[truncated to #{cap} bytes]" if err_truncated
        [out, err]
      end

      def append_capped(buffer, chunk, cap)
        if (buffer.bytesize + chunk.bytesize) <= cap
          buffer << chunk
          return true
        end

        remaining = cap - buffer.bytesize
        buffer << chunk.byteslice(0, remaining) if remaining.positive?
        false
      end

      # Output discovery, in priority order:
      #
      #   1. /prouter/output.json exists and parses → use that.
      #      An explicit file is the strongest signal of intent.
      #   2. /prouter/output.json exists but is empty → output_json={}.
      #   3. /prouter/output.json missing, stdout parses as a JSON
      #      Hash/Array → use that. Lets blocks emit JSON via stdout
      #      without `> /prouter/output.json` ceremony, mirroring
      #      ShellRunner. The single-block scorer becomes
      #      `command \`echo '{"score":85}'\`` with zero escapes.
      #   4. Otherwise (missing file, plain log stdout, JSON scalar) →
      #      output_json={}. Side-effect-only blocks stay valid.
      #
      # Malformed JSON in an explicit output.json still surfaces as
      # invalid_output — the file was a deliberate write.
      def classify_outcome(work_dir, exit_code, stdout_str)
        output_path = File.join(work_dir, OUTPUT_FILENAME)
        if exit_code != 0
          # Preserve any structured output the failing container managed
          # to emit before bailing — operator can inspect via `show run`/
          # `show logs`. Downstream context propagation stays gated on
          # success in BlockExecutor, so this only affects the persisted
          # step row.
          return ["non_zero_exit", "block exited with code #{exit_code}",
                  extract_partial_output(work_dir, stdout_str)]
        end

        if File.exist?(output_path)
          raw = File.read(output_path)
          return [nil, nil, {}] if raw.empty?

          begin
            return [nil, nil, JSON.parse(raw)]
          rescue JSON::ParserError => e
            return ["invalid_output", "output.json is not valid JSON: #{e.message}", nil]
          end
        end

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

      # Best-effort recovery of a structured payload from a failed
      # container run. Returns nil when neither output.json nor stdout
      # yield a Hash/Array — the step still persists with output_json=nil
      # and the operator falls back to the captured stdout/stderr.
      def extract_partial_output(work_dir, stdout_str)
        output_path = File.join(work_dir, OUTPUT_FILENAME)
        if File.exist?(output_path)
          raw = File.read(output_path).to_s
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

        descriptors = []
        Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
          stat = File.lstat(path)
          next unless stat.file?

          rel_name = path.sub(/\A#{Regexp.escape(dir)}\/?/, "")
          next if rel_name.empty?

          size = stat.size
          checksum = file_checksum(path)
          descriptors << ArtifactDescriptor.new(
            name: rel_name,
            host_path: path,
            size_bytes: size,
            content_type: nil,
            checksum: checksum
          )
        rescue SystemCallError
          next
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
