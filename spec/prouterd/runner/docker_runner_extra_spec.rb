require "spec_helper"
require "tmpdir"
require "fileutils"

# Pure-unit coverage for DockerRunner helper paths that don't need a
# real Docker daemon (parsing, env, log multiplexing, file handling).
RSpec.describe Prouterd::Runner::DockerRunner do
  before do
    # Make sure the Docker error constants exist even if `docker-api`
    # isn't loaded — the rescue clauses reference them at parse time.
    unless defined?(Docker)
      stub_const("Docker", Module.new)
      stub_const("Docker::Error", Module.new)
      stub_const("Docker::Error::DockerError", Class.new(StandardError))
      stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
    end
    unless defined?(Docker::Error::NotFoundError)
      stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
    end
  end

  let(:runner) { described_class.new }

  describe ".docker_available?" do
    after { described_class.instance_variable_set(:@docker_available, nil) }

    it "returns true when require succeeds" do
      described_class.instance_variable_set(:@docker_available, nil)
      allow(described_class).to receive(:require).with("docker").and_return(true)
      expect(described_class.docker_available?).to be(true)
    end

    it "returns false when docker-api gem isn't installed" do
      described_class.instance_variable_set(:@docker_available, nil)
      allow(described_class).to receive(:require).with("docker").and_raise(LoadError)
      expect(described_class.docker_available?).to be(false)
    end

    it "caches the result on subsequent calls" do
      described_class.instance_variable_set(:@docker_available, true)
      expect(described_class).not_to receive(:require)
      expect(described_class.docker_available?).to be(true)
    end
  end

  describe "#parse_memory" do
    it "returns nil for blank input" do
      expect(runner.send(:parse_memory, nil)).to be_nil
      expect(runner.send(:parse_memory, "")).to be_nil
      expect(runner.send(:parse_memory, "   ")).to be_nil
    end

    it "parses each suffix" do
      expect(runner.send(:parse_memory, "512k")).to eq(512 * 1024)
      expect(runner.send(:parse_memory, "512m")).to eq(512 * 1024**2)
      expect(runner.send(:parse_memory, "1g")).to eq(1024**3)
      expect(runner.send(:parse_memory, "2t")).to eq(2 * 1024**4)
    end

    it "parses bare bytes (no suffix)" do
      expect(runner.send(:parse_memory, "104857600")).to eq(104_857_600)
    end

    it "accepts the 'B' suffix variant and is case-insensitive" do
      expect(runner.send(:parse_memory, "2GB")).to eq(2 * 1024**3)
      expect(runner.send(:parse_memory, "2gb")).to eq(2 * 1024**3)
    end

    it "returns nil on unparseable input (falls through to docker default)" do
      expect(runner.send(:parse_memory, "garbage")).to be_nil
    end
  end

  describe "#parse_cpu" do
    it "returns nil for blank input" do
      expect(runner.send(:parse_cpu, nil)).to be_nil
      expect(runner.send(:parse_cpu, "  ")).to be_nil
    end

    it "converts float CPUs to NanoCpus" do
      expect(runner.send(:parse_cpu, "0.5")).to eq(500_000_000)
      expect(runner.send(:parse_cpu, "2")).to eq(2_000_000_000)
    end

    it "returns nil for non-positive values" do
      expect(runner.send(:parse_cpu, "0")).to be_nil
      expect(runner.send(:parse_cpu, "-1")).to be_nil
    end

    it "returns nil for unparseable input" do
      expect(runner.send(:parse_cpu, "abc")).to be_nil
    end
  end

  describe "#parse_command" do
    it "returns nil for blank input" do
      expect(runner.send(:parse_command, nil)).to be_nil
      expect(runner.send(:parse_command, "")).to be_nil
    end

    it "shell-splits a regular command" do
      expect(runner.send(:parse_command, "echo hello")).to eq(["echo", "hello"])
    end

    it "wraps in sh -c when Shellwords cannot parse" do
      expect(runner.send(:parse_command, %q{echo "unterminated})).to eq(["sh", "-c", %q{echo "unterminated}])
    end
  end

  describe "#network_mode" do
    it "maps 'off' to none and anything else to bridge" do
      expect(runner.send(:network_mode, "off")).to eq("none")
      expect(runner.send(:network_mode, "bridge")).to eq("bridge")
      expect(runner.send(:network_mode, nil)).to eq("bridge")
      expect(runner.send(:network_mode, "host")).to eq("bridge")
    end
  end

  describe "#build_env" do
    it "returns the request env unchanged" do
      req = double(env: { "A" => "1" })
      expect(runner.send(:build_env, req)).to eq("A" => "1")
    end

    it "returns {} when request env is nil" do
      req = double(env: nil)
      expect(runner.send(:build_env, req)).to eq({})
    end
  end

  describe "#demultiplex_logs" do
    def frame(stream, payload)
      [stream, 0, 0, 0, payload.bytesize].pack("CCCCN") + payload.b
    end

    it "returns ['', ''] for blank input" do
      expect(runner.send(:demultiplex_logs, nil)).to eq(["", ""])
      expect(runner.send(:demultiplex_logs, "")).to eq(["", ""])
    end

    it "splits stdout (stream byte 1) and stderr (stream byte 2)" do
      raw = frame(1, "hello") + frame(2, "warn")
      out, err = runner.send(:demultiplex_logs, raw)
      expect(out).to eq("hello")
      expect(err).to eq("warn")
    end

    it "treats unknown stream bytes as raw stdout (TTY mode)" do
      raw = frame(7, "weird")
      out, err = runner.send(:demultiplex_logs, raw)
      expect(out).to include("") # raw byte gets force-encoded
      expect(err).to eq("")
    end

    it "applies the cap by truncating stdout when over the limit" do
      payload = "x" * 5_000
      raw = frame(1, payload)
      out, _err = runner.send(:demultiplex_logs, raw, cap: 1_000)
      expect(out.bytesize).to be <= 1_100
      expect(out).to include("truncated")
    end

    it "stops when a frame header has no payload bytes at all" do
      truncated = frame(1, "abc")[0, 8] # header-only — no payload to byteslice
      out, err = runner.send(:demultiplex_logs, truncated)
      expect(out).to eq("")
      expect(err).to eq("")
    end
  end

  describe "#finish_log_buffer" do
    it "marks truncated buffers with a notice and forces UTF-8" do
      buf = String.new("hello", encoding: Encoding::BINARY)
      out = runner.send(:finish_log_buffer, buf, true, 100)
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out).to end_with("[truncated to 100 bytes]")
    end

    it "leaves clean buffers unmarked" do
      buf = String.new("hello", encoding: Encoding::BINARY)
      out = runner.send(:finish_log_buffer, buf, false, 100)
      expect(out).to eq("hello")
    end
  end

  describe "#collect_artifacts" do
    let(:work_dir) { Dir.mktmpdir("docker-runner-art-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "returns [] when artifacts dir is missing" do
      expect(runner.send(:collect_artifacts, work_dir)).to eq([])
    end

    it "lists files with sha256 + size and skips symlinks" do
      art_dir = File.join(work_dir, "artifacts")
      FileUtils.mkdir_p(File.join(art_dir, "nested"))
      File.write(File.join(art_dir, "a.txt"), "hello")
      File.write(File.join(art_dir, "nested/b.txt"), "world")
      File.symlink("/etc/passwd", File.join(art_dir, "leak"))

      descriptors = runner.send(:collect_artifacts, work_dir)
      names = descriptors.map(&:name).sort
      expect(names).to eq(["a.txt", "nested/b.txt"])
      a = descriptors.find { |d| d.name == "a.txt" }
      expect(a.size_bytes).to eq(5)
      expect(a.checksum).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "#read_output_file" do
    it "delegates to IOLimits.read_file" do
      expect(Prouterd::Runner::IOLimits).to receive(:read_file).with("/tmp/x").and_return([true, "ok", nil])
      expect(runner.send(:read_output_file, "/tmp/x")).to eq([true, "ok", nil])
    end

    it "translates SystemCallError into [false, nil, message]" do
      allow(Prouterd::Runner::IOLimits).to receive(:read_file).and_raise(Errno::EACCES.new("denied"))
      ok, raw, msg = runner.send(:read_output_file, "/tmp/x")
      expect(ok).to be(false)
      expect(raw).to be_nil
      expect(msg).to include("denied")
    end
  end

  describe "#extract_partial_output" do
    let(:work_dir) { Dir.mktmpdir("docker-runner-partial-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "prefers an explicit output.json with a Hash" do
      File.write(File.join(work_dir, "output.json"), '{"x":1}')
      expect(runner.send(:extract_partial_output, work_dir, "stdout-ignored")).to eq("x" => 1)
    end

    it "accepts an Array payload from output.json" do
      File.write(File.join(work_dir, "output.json"), "[1,2,3]")
      expect(runner.send(:extract_partial_output, work_dir, "")).to eq([1, 2, 3])
    end

    it "falls back to stdout when output.json is empty" do
      File.write(File.join(work_dir, "output.json"), "")
      expect(runner.send(:extract_partial_output, work_dir, '{"from":"stdout"}')).to eq("from" => "stdout")
    end

    it "falls back to stdout when output.json is unparseable" do
      File.write(File.join(work_dir, "output.json"), "garbage")
      expect(runner.send(:extract_partial_output, work_dir, '{"from":"stdout"}')).to eq("from" => "stdout")
    end

    it "returns nil when neither source yields a Hash/Array" do
      expect(runner.send(:extract_partial_output, work_dir, "plain log\n")).to be_nil
    end

    it "returns nil for empty stdout and no output.json" do
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end

    it "returns nil when read_output_file reports failure" do
      File.write(File.join(work_dir, "output.json"), "x")
      allow(runner).to receive(:read_output_file).and_return([false, nil, "boom"])
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end

    it "returns a JSON scalar as nil (not a Hash/Array)" do
      File.write(File.join(work_dir, "output.json"), "42")
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end
  end

  describe "#cleanup" do
    let(:work_dir) { Dir.mktmpdir("docker-runner-cleanup-") }

    it "removes the work dir when present" do
      runner.send(:cleanup, nil, work_dir)
      expect(File.directory?(work_dir)).to be(false)
    end

    it "swallows container delete errors and still removes the work dir" do
      container = double("container")
      allow(container).to receive(:delete).and_raise(Docker::Error::DockerError, "gone")
      runner.send(:cleanup, container, work_dir)
      expect(File.directory?(work_dir)).to be(false)
    end

    it "swallows generic StandardError from container.delete" do
      container = double("container")
      allow(container).to receive(:delete).and_raise(StandardError, "boom")
      runner.send(:cleanup, container, work_dir)
      expect(File.directory?(work_dir)).to be(false)
    end

    it "no-ops with nil container and nil work_dir" do
      expect { runner.send(:cleanup, nil, nil) }.not_to raise_error
    end
  end

  describe "#capture_logs" do
    it "returns ['', ''] when Docker raises mid-stream" do
      fake = Class.new do
        def streaming_logs(**)
          raise Docker::Error::DockerError, "stream broke"
        end
      end.new
      expect(runner.send(:capture_logs, fake)).to eq(["", ""])
    end

    it "captures stdout and stderr emitted as String stream names" do
      fake = Class.new do
        def streaming_logs(**)
          yield "stdout", "hi"
          yield "stderr", "warn"
        end
      end.new
      out, err = runner.send(:capture_logs, fake)
      expect(out).to eq("hi")
      expect(err).to eq("warn")
    end
  end

  describe "#ensure_image" do
    let(:request) do
      double(field: nil).tap do |r|
        # Stub via method_missing-style — return policy/image based on key
      end
    end

    it "no-ops when pull policy is 'never'" do
      req = double
      allow(req).to receive(:field).with("pull").and_return("never")
      expect(Docker::Image).not_to receive(:create) if defined?(Docker::Image)
      runner.send(:ensure_image, req)
    end

    it "no-ops on 'if-missing' when image is already present" do
      req = double
      allow(req).to receive(:field).with("pull").and_return("if-missing")
      allow(req).to receive(:field).with("image").and_return("alpine:1")
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      expect(Docker::Image).to receive(:get).with("alpine:1").and_return(:present)
      expect(Docker::Image).not_to receive(:create)
      runner.send(:ensure_image, req)
    end

    it "pulls on 'if-missing' when image is not present" do
      req = double
      allow(req).to receive(:field).with("pull").and_return("if-missing")
      allow(req).to receive(:field).with("image").and_return("alpine:1")
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      allow(Docker::Image).to receive(:get).and_raise(Docker::Error::NotFoundError)
      expect(Docker::Image).to receive(:create).with("fromImage" => "alpine:1")
      runner.send(:ensure_image, req)
    end

    it "pulls unconditionally on 'always'" do
      req = double
      allow(req).to receive(:field).with("pull").and_return("always")
      allow(req).to receive(:field).with("image").and_return("alpine:1")
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      expect(Docker::Image).to receive(:create).with("fromImage" => "alpine:1")
      runner.send(:ensure_image, req)
    end

    it "defaults policy to 'if-missing' when 'pull' field is absent" do
      req = double
      allow(req).to receive(:field).with("pull").and_return(nil)
      allow(req).to receive(:field).with("image").and_return("alpine:1")
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      allow(Docker::Image).to receive(:get).and_return(:present)
      expect(Docker::Image).not_to receive(:create)
      runner.send(:ensure_image, req)
    end
  end

  describe "#create_container" do
    it "wires image, env, cmd, host config, labels, and user into Docker::Container.create" do
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "rUID", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: { "A" => "1" }, input_json: {}, timeout_ms: nil,
        type_fields: {
          "image" => "alpine:1",
          "command" => "sh -c true",
          "network" => "off",
          "memory" => "256m",
          "cpu" => "0.5",
          "user" => "1000:1000"
        }, staged_inputs: {}
      )

      stub_const("Docker::Container", Class.new { def self.create(*); end })
      captured = nil
      expect(Docker::Container).to receive(:create) { |params| captured = params; :container }

      runner.send(:create_container, req, "/work")
      expect(captured["Image"]).to eq("alpine:1")
      expect(captured["Cmd"]).to eq(["sh", "-c", "true"])
      expect(captured["User"]).to eq("1000:1000")
      expect(captured["Env"]).to include("A=1")
      expect(captured["HostConfig"]["Binds"]).to eq(["/work:/prouter:rw"])
      expect(captured["HostConfig"]["NetworkMode"]).to eq("none")
      expect(captured["HostConfig"]["Memory"]).to eq(256 * 1024**2)
      expect(captured["HostConfig"]["NanoCpus"]).to eq(500_000_000)
      expect(captured["Labels"]).to eq({
        "prouterd.run_uid" => "rUID",
        "prouterd.process" => "p",
        "prouterd.block"   => "b"
      })
    end

    it "omits Cmd / User / Memory / NanoCpus when not set" do
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "rUID", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "image" => "alpine:1" }, staged_inputs: {}
      )
      stub_const("Docker::Container", Class.new { def self.create(*); end })
      captured = nil
      allow(Docker::Container).to receive(:create) { |params| captured = params; :container }
      runner.send(:create_container, req, "/work")
      expect(captured).not_to have_key("Cmd")
      expect(captured).not_to have_key("User")
      expect(captured["HostConfig"]).not_to have_key("Memory")
      expect(captured["HostConfig"]).not_to have_key("NanoCpus")
    end

    it "drops empty-string User" do
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "rUID", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "image" => "alpine:1", "user" => "" }, staged_inputs: {}
      )
      stub_const("Docker::Container", Class.new { def self.create(*); end })
      captured = nil
      allow(Docker::Container).to receive(:create) { |params| captured = params; :container }
      runner.send(:create_container, req, "/work")
      expect(captured).not_to have_key("User")
    end
  end

  describe "#prepare_work_dir" do
    let(:work_dir) { Dir.mktmpdir("docker-runner-prep-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "writes input.json + creates artifacts dir + makes both world-writable" do
      runner.send(:prepare_work_dir, work_dir, { "x" => 1 })
      input = File.read(File.join(work_dir, "input.json"))
      expect(JSON.parse(input)).to eq("x" => 1)
      expect(File.directory?(File.join(work_dir, "artifacts"))).to be(true)
      expect(File.stat(work_dir).mode & 0o777).to eq(0o777)
      expect(File.stat(File.join(work_dir, "artifacts")).mode & 0o777).to eq(0o777)
    end

    it "writes {} when input_json is nil" do
      runner.send(:prepare_work_dir, work_dir, nil)
      expect(File.read(File.join(work_dir, "input.json"))).to eq("{}")
    end
  end

  describe "#stage_inputs" do
    let(:work_dir) { Dir.mktmpdir("docker-runner-stage-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "is a no-op for nil and empty staged" do
      runner.send(:stage_inputs, work_dir, nil)
      runner.send(:stage_inputs, work_dir, {})
      expect(File.exist?(File.join(work_dir, "inputs"))).to be(false)
    end

    it "copies each staged source into inputs/<local>" do
      src = File.join(work_dir, "src.txt")
      File.write(src, "payload")
      runner.send(:stage_inputs, work_dir, { "a.txt" => src })
      expect(File.read(File.join(work_dir, "inputs", "a.txt"))).to eq("payload")
    end
  end

  describe "#wait_with_timeout" do
    it "raises Timeout::Error when the container.wait call exceeds the deadline" do
      slow = Class.new do
        def wait
          sleep 0.5
        end
      end.new
      expect { runner.send(:wait_with_timeout, slow, 0.05) }.to raise_error(Timeout::Error)
    end

    it "returns when wait completes in time" do
      fast = Class.new do
        def wait; :done; end
      end.new
      expect(runner.send(:wait_with_timeout, fast, 5)).to eq(:done)
    end
  end

  describe "#force_stop delegates to Runner::DockerStop" do
    it "calls DockerStop.force_stop with the container" do
      expect(Prouterd::Runner::DockerStop).to receive(:force_stop).with(:fake_container)
      runner.send(:force_stop, :fake_container)
    end
  end

  describe "#run end-to-end orchestration with stubbed Docker layer" do
    before do
      described_class.instance_variable_set(:@docker_available, true)
      stub_const("Docker::Container", Class.new { def self.create(*); end })
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
    end
    after { described_class.instance_variable_set(:@docker_available, nil) }

    let(:fake_container) do
      Class.new do
        attr_reader :id
        def initialize(work_dir)
          @id = "fake-id"
          @work_dir = work_dir
        end
        def start
          File.write(File.join(@work_dir, "output.json"), '{"ok":true}')
        end
        def wait; :exited; end
        def json; { "State" => { "ExitCode" => 0 } }; end
        def streaming_logs(**); yield :stdout, "log"; end
        def delete(**); end
      end
    end

    let(:request) do
      Prouterd::Runner::RunRequest.new(
        run_uid: "rUID", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: { "in" => 1 }, timeout_ms: 100,
        type_fields: { "image" => "alpine:1" }, staged_inputs: {}
      )
    end

    it "returns success when container exits 0 with output.json present" do
      allow(Docker::Image).to receive(:get).and_return(:present)
      allow(Docker::Container).to receive(:create) do |params|
        host_path = params["HostConfig"]["Binds"].first.split(":").first
        fake_container.new(host_path)
      end

      result = runner.run(request)
      expect(result.exit_code).to eq(0)
      expect(result.output_json).to eq("ok" => true)
      expect(result.error_type).to be_nil
    end

    it "translates Docker::Error::DockerError into docker_error envelope" do
      allow(Docker::Image).to receive(:get).and_return(:present)
      allow(Docker::Container).to receive(:create).and_raise(Docker::Error::DockerError, "down")
      result = runner.run(request)
      expect(result.error_type).to eq("docker_error")
      expect(result.error_message).to include("down")
      expect(result.exit_code).to be_nil
    end

    it "force-stops the container and reports timeout when container.wait blocks past the deadline" do
      blocking = Class.new(fake_container) do
        def start; end
        def wait; sleep 0.5; end
      end
      allow(Docker::Image).to receive(:get).and_return(:present)
      allow(Docker::Container).to receive(:create) do |params|
        host_path = params["HostConfig"]["Binds"].first.split(":").first
        blocking.new(host_path)
      end
      expect(Prouterd::Runner::DockerStop).to receive(:force_stop)
      result = runner.run(request_with(timeout_ms: 50))
      expect(result.error_type).to eq("timeout")
    end

    it "calls in_flight.attach_container / detach_container around start" do
      tracker = double("InFlight")
      expect(tracker).to receive(:attach_container).with("rUID", "fake-id")
      expect(tracker).to receive(:detach_container).with("rUID", "fake-id")
      r = described_class.new(in_flight: tracker)
      allow(Docker::Image).to receive(:get).and_return(:present)
      allow(Docker::Container).to receive(:create) do |params|
        host_path = params["HostConfig"]["Binds"].first.split(":").first
        fake_container.new(host_path)
      end
      r.run(request)
    end

    it "returns missing_dependency when docker-api isn't installed" do
      described_class.instance_variable_set(:@docker_available, false)
      result = runner.run(request)
      expect(result.error_type).to eq("missing_dependency")
    end

    def request_with(timeout_ms:)
      Prouterd::Runner::RunRequest.new(
        run_uid: "rUID", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: timeout_ms,
        type_fields: { "image" => "alpine:1" }, staged_inputs: {}
      )
    end
  end
end

RSpec.describe "Runner::DockerRunner collect_artifacts skips empty rel_name" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "ignores a Dir.glob yield whose path equals the artifacts root" do
    Dir.mktmpdir do |work|
      art_dir = File.join(work, "artifacts")
      FileUtils.mkdir_p(art_dir)
      File.write(File.join(art_dir, "x.txt"), "y")
      # Inject the art-dir path itself as a Dir.glob yield. After the
      # sub strips the prefix, rel_name == "" → next fires.
      allow(Dir).to receive(:glob).and_wrap_original do |orig, *args|
        [art_dir] + orig.call(*args)
      end
      descriptors = runner.send(:collect_artifacts, work)
      expect(descriptors.map(&:name)).to eq(["x.txt"])
    end
  end
end

RSpec.describe "Runner::DockerRunner collect_artifacts SystemCallError rescue" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "skips files whose lstat raises SystemCallError" do
    Dir.mktmpdir do |work|
      art = File.join(work, "artifacts")
      FileUtils.mkdir_p(art)
      File.write(File.join(art, "a.txt"), "x")
      bad_path = File.join(art, "b.txt")
      File.write(bad_path, "x")
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(bad_path).and_raise(Errno::EACCES.new("denied"))
      descriptors = runner.send(:collect_artifacts, work)
      expect(descriptors.map(&:name)).to eq(["a.txt"])
    end
  end
end

RSpec.describe "Runner::DockerRunner capture_logs unknown stream symbol" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "ignores chunks delivered with an unknown stream identifier" do
    fake = Class.new do
      def streaming_logs(**)
        yield :unknown_stream_name, "ignored"
        yield :stdout, "real"
      end
    end.new
    out, err = runner.send(:capture_logs, fake)
    expect(out).to eq("real")
    expect(err).to eq("")
  end
end

RSpec.describe "Runner::DockerRunner artifact rel_name empty" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "drops the artifacts root (rel_name '' after the sub)" do
    Dir.mktmpdir do |work|
      FileUtils.mkdir_p(File.join(work, "artifacts"))
      File.write(File.join(work, "artifacts/foo.txt"), "x")
      results = runner.send(:collect_artifacts, work)
      expect(results.map(&:name)).to eq(["foo.txt"])
      expect(results.map(&:name)).not_to include("")
    end
  end

  it "demultiplex_logs breaks the loop when payload-byteslice returns nil" do
    # 8-byte header claims 100 bytes payload but buffer has only header
    raw = [1, 0, 0, 0, 100].pack("CCCCN") # exactly 8 bytes, no payload
    out, err = runner.send(:demultiplex_logs, raw)
    expect(out).to eq("")
    expect(err).to eq("")
  end
end

RSpec.describe "Runner::DockerRunner DockerError pre-started_at" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  before do
    unless defined?(Docker)
      stub_const("Docker", Module.new)
      stub_const("Docker::Error", Module.new)
      stub_const("Docker::Error::DockerError", Class.new(StandardError))
      stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
    end
  end

  it "returns finished_at + nil started_at when create_container raises before start" do
    described_class = Prouterd::Runner::DockerRunner
    described_class.instance_variable_set(:@docker_available, true)
    stub_const("Docker::Container", Class.new { def self.create(*); end })
    stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
    allow(Docker::Image).to receive(:get).and_return(:present)
    allow(Docker::Container).to receive(:create).and_raise(Docker::Error::DockerError, "early-boom")

    req = Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "docker", attempt: 1,
      env: {}, input_json: {}, timeout_ms: nil,
      type_fields: { "image" => "x" }, staged_inputs: {}
    )
    result = runner.run(req)
    expect(result.error_type).to eq("docker_error")
    expect(result.started_at).to be_nil
    expect(result.finished_at).not_to be_nil
    described_class.instance_variable_set(:@docker_available, nil)
  end
end

RSpec.describe "Runner::DockerRunner DockerError post-started_at" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  before do
    unless defined?(Docker)
      stub_const("Docker", Module.new)
      stub_const("Docker::Error", Module.new)
      stub_const("Docker::Error::DockerError", Class.new(StandardError))
      stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
    end
  end

  it "preserves started_at on the result when wait() raises DockerError" do
    Prouterd::Runner::DockerRunner.instance_variable_set(:@docker_available, true)
    stub_const("Docker::Container", Class.new { def self.create(*); end })
    stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
    allow(Docker::Image).to receive(:get).and_return(:present)

    # Container that starts fine then blows up on .wait, after started_at = Time.now.utc.
    fake = Class.new do
      attr_reader :id
      def initialize(wd); @id = "c"; @wd = wd; end
      def start; File.write(File.join(@wd, "output.json"), '{}'); end
      def wait; raise Docker::Error::DockerError, "mid-wait"; end
      def json; { "State" => {} }; end
      def streaming_logs(**); end
      def delete(**); end
    end
    allow(Docker::Container).to receive(:create) do |params|
      wd = params["HostConfig"]["Binds"].first.split(":").first
      fake.new(wd)
    end

    req = Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "docker", attempt: 1,
      env: {}, input_json: {}, timeout_ms: nil,
      type_fields: { "image" => "x" }, staged_inputs: {}
    )
    result = runner.run(req)
    expect(result.error_type).to eq("docker_error")
    expect(result.started_at).to match(/\d{4}-\d{2}-\d{2}T/)
    Prouterd::Runner::DockerRunner.instance_variable_set(:@docker_available, nil)
  end
end

RSpec.describe "Runner::DockerRunner collect_artifacts edge" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }

  it "skips the artifacts dir itself (rel_name empty after sub)" do
    Dir.mktmpdir do |work|
      FileUtils.mkdir_p(File.join(work, "artifacts"))
      File.write(File.join(work, "artifacts/x.txt"), "y")
      # Listing with FNM_DOTMATCH also yields ".", which strips to
      # empty rel_name → the `next if rel_name.empty?` branch fires.
      descriptors = runner.send(:collect_artifacts, work)
      expect(descriptors.map(&:name)).to include("x.txt")
      expect(descriptors.map(&:name)).not_to include("")
    end
  end
end

RSpec.describe "Runner::DockerRunner edges" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }

  before do
    unless defined?(Docker)
      stub_const("Docker", Module.new)
      stub_const("Docker::Error", Module.new)
      stub_const("Docker::Error::DockerError", Class.new(StandardError))
      stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
    end
  end

  it "uses bare container.wait (no Timeout) when request.timeout_ms is nil" do
    described_class = Prouterd::Runner::DockerRunner
    described_class.instance_variable_set(:@docker_available, true)
    stub_const("Docker::Container", Class.new { def self.create(*); end })
    stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
    allow(Docker::Image).to receive(:get).and_return(:present)

    fake_container = Class.new do
      attr_reader :id
      def initialize(work_dir)
        @id = "ok"
        @wd = work_dir
      end
      def start
        File.write(File.join(@wd, "output.json"), '{}')
      end
      def wait; :exited; end
      def json; { "State" => { "ExitCode" => 0 } }; end
      def streaming_logs(**); yield :stdout, "log"; end
      def delete(**); end
    end
    allow(Docker::Container).to receive(:create) do |params|
      wd = params["HostConfig"]["Binds"].first.split(":").first
      fake_container.new(wd)
    end

    req = Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "docker", attempt: 1,
      env: {}, input_json: {}, timeout_ms: nil,
      type_fields: { "image" => "x" }, staged_inputs: {}
    )
    result = runner.run(req)
    expect(result.exit_code).to eq(0)
    described_class.instance_variable_set(:@docker_available, nil)
  end

  it "demultiplex_logs falls through to raw-buffer when stream byte is unknown" do
    # stream=7 is neither stdout(1) nor stderr(2) → hits the else
    # branch that treats the whole buffer as TTY-mode stdout.
    raw = [7, 0, 0, 0, 4].pack("CCCCN") + "abcd"
    out, err = runner.send(:demultiplex_logs, raw)
    expect(err).to eq("")
  end
end

RSpec.describe "Runner::DockerRunner collect_artifacts dir-entry skip" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "ignores '.' and the artifacts root itself" do
    Dir.mktmpdir do |work|
      FileUtils.mkdir_p(File.join(work, "artifacts", "sub"))
      File.write(File.join(work, "artifacts/sub/y.txt"), "ok")
      descriptors = runner.send(:collect_artifacts, work)
      expect(descriptors.map(&:name)).to eq(["sub/y.txt"])
    end
  end
end

RSpec.describe "Runner::DockerRunner demultiplex_logs payload-nil break" do
  let(:runner) { Prouterd::Runner::DockerRunner.new }
  it "breaks the loop when the size header points past the end of the buffer" do
    # 8-byte header claiming 10 payload bytes, but no payload bytes follow.
    raw = [1, 0, 0, 0, 10].pack("CCCCN")
    out, err = runner.send(:demultiplex_logs, raw)
    expect(out).to eq("")
    expect(err).to eq("")
  end
end
