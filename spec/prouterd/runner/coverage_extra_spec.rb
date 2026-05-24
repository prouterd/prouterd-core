require "spec_helper"
require "tempfile"

# Stub out the docker-api Docker::Error::DockerError constant if the
# gem isn't loaded (it's an optional dep). Docker_stop.rb references
# the constant in a rescue clause that loads only when the gem is
# present, so we provide a placeholder for unit tests of the rescue.
module Docker
  module Error
    class DockerError < StandardError; end
  end
end unless defined?(Docker::Error::DockerError)

# Targeted micro-specs for the small runner files. Pure unit
# coverage for branches that the broader runner tests don't hit.
RSpec.describe Prouterd::Runner::CallRunner do
  let(:registry) { Prouterd::Iface::Registry }

  it "returns invalid_interface_type when no plugin is registered for the requested type" do
    runner = described_class.new
    request = Prouterd::Runner::RunRequest.new(
      execution_type: "ghost",
      block_name: "b", run_uid: "r", process_name: "p",
      attempt: 1, env: {}, input_json: {}, type_fields: {}
    )
    allow(registry).to receive(:lookup).with("ghost").and_return(nil)

    result = runner.run(request)
    expect(result.error_type).to eq("invalid_interface_type")
    expect(result.error_message).to include("ghost")
  end

  it "wraps unexpected StandardError as dispatch_error" do
    runner = described_class.new
    boom_klass = Class.new do
      def initialize(*); end
      def run(_req); raise RuntimeError, "boom"; end
    end
    plugin = double("plugin", caller_class: boom_klass)
    allow(registry).to receive(:lookup).and_return(plugin)

    request = Prouterd::Runner::RunRequest.new(
      execution_type: "boom_type",
      block_name: "b", run_uid: "r", process_name: "p",
      attempt: 1, env: {}, input_json: {}, type_fields: {}
    )

    result = runner.run(request)
    expect(result.error_type).to eq("dispatch_error")
    expect(result.error_message).to include("RuntimeError: boom")
  end

  it "passes in_flight / warm_pool only to callers that accept those kwargs" do
    accepting_klass = Class.new do
      attr_reader :in_flight, :warm_pool
      def initialize(in_flight: nil, warm_pool: nil)
        @in_flight = in_flight
        @warm_pool = warm_pool
      end
      def run(_req); Prouterd::Runner::ExecutionResult.new(exit_code: 0, error_type: nil); end
    end

    sentinel_if = Object.new
    sentinel_wp = Object.new
    runner = described_class.new(in_flight: sentinel_if, warm_pool: sentinel_wp)

    plugin = double("plugin", caller_class: accepting_klass)
    allow(registry).to receive(:lookup).and_return(plugin)

    request = Prouterd::Runner::RunRequest.new(
      execution_type: "x",
      block_name: "b", run_uid: "r", process_name: "p",
      attempt: 1, env: {}, input_json: {}, type_fields: {}
    )
    runner.run(request)
    instance = runner.instance_variable_get(:@cache)[accepting_klass]
    expect(instance.in_flight).to eq(sentinel_if)
    expect(instance.warm_pool).to eq(sentinel_wp)
  end
end

RSpec.describe Prouterd::Runner::StubRunner do
  it "program_next consumes FIFO programmed handlers" do
    runner = described_class.new
    runner.program_next { |_req| Prouterd::Runner::StubRunner.success(output: { "v" => 1 }).call(nil) }
    runner.program_next { |_req| Prouterd::Runner::StubRunner.success(output: { "v" => 2 }).call(nil) }

    req = Prouterd::Runner::RunRequest.new(execution_type: "x", block_name: "a", run_uid: "r",
                                            process_name: "p", attempt: 1, env: {}, input_json: {}, type_fields: {})
    expect(runner.run(req).output_json["v"]).to eq(1)
    expect(runner.run(req).output_json["v"]).to eq(2)
  end

  it "default handler overrides the built-in default" do
    runner = described_class.new
    runner.default { |req| Prouterd::Runner::ExecutionResult.new(exit_code: 42, error_type: "stubbed", output_json: nil, stdout: "", stderr: "", artifacts: [], error_message: nil, duration_ms: 0, started_at: nil, finished_at: nil) }

    req = Prouterd::Runner::RunRequest.new(execution_type: "x", block_name: "unprogrammed", run_uid: "r",
                                            process_name: "p", attempt: 1, env: {}, input_json: {}, type_fields: {})
    expect(runner.run(req).exit_code).to eq(42)
    expect(runner.run(req).error_type).to eq("stubbed")
  end
end

RSpec.describe Prouterd::Runner::IOLimits do
  it "env_limit falls back to the default when the env var is unset / zero" do
    ENV.delete("PROUTERD_IO_TEST")
    expect(described_class.env_limit("PROUTERD_IO_TEST", 4242)).to eq(4242)
    ENV["PROUTERD_IO_TEST"] = "0"
    expect(described_class.env_limit("PROUTERD_IO_TEST", 4242)).to eq(4242)
  ensure
    ENV.delete("PROUTERD_IO_TEST")
  end

  it "env_limit honors a positive env value" do
    ENV["PROUTERD_IO_TEST"] = "777"
    expect(described_class.env_limit("PROUTERD_IO_TEST", 4242)).to eq(777)
  ensure
    ENV.delete("PROUTERD_IO_TEST")
  end

  it "read_stream returns the empty string on IOError" do
    io = StringIO.new("hello world")
    allow(io).to receive(:read).and_raise(IOError)
    expect(described_class.read_stream(io)).to eq("")
  end

  it "read_stream caps oversized input and appends a truncation marker" do
    io = StringIO.new("x" * 10_000)
    out = described_class.read_stream(io, cap: 100)
    expect(out).to include("truncated to 100 bytes")
    expect(out.bytesize).to be <= 200
  end

  it "read_file returns [false, nil, message] when the file exceeds the cap" do
    Tempfile.create do |f|
      f.write("y" * 200)
      f.flush
      ok, buf, err = described_class.read_file(f.path, cap: 50)
      expect(ok).to be(false)
      expect(buf).to be_nil
      expect(err).to include("exceeds 50 bytes")
    end
  end

  it "read_file returns [true, buffer, nil] for files within the cap" do
    Tempfile.create do |f|
      f.write("hello world")
      f.flush
      ok, buf, err = described_class.read_file(f.path, cap: 1024)
      expect(ok).to be(true)
      expect(buf).to eq("hello world")
      expect(err).to be_nil
    end
  end

  describe "append_capped at-the-cap boundary" do
    it "drops the entire chunk when buffer already equals cap (remaining=0)" do
      buf = String.new("xxxxx", encoding: Encoding::BINARY)
      ok = described_class.append_capped(buf, "yyy", 5)
      expect(ok).to be(false)
      expect(buf).to eq("xxxxx")
    end

    it "partially appends when only some remaining bytes fit" do
      buf = String.new("xx", encoding: Encoding::BINARY)
      ok = described_class.append_capped(buf, "abcdef", 5)
      expect(ok).to be(false)
      expect(buf).to eq("xxabc")
    end
  end
end

RSpec.describe Prouterd::Runner::DockerStop do
  it "calls container.stop with the configured timeout" do
    container = double("container")
    expect(container).to receive(:stop).with("t" => described_class::DEFAULT_STOP_TIMEOUT)
    described_class.force_stop(container)
  end

  it "honors PROUTERD_CONTAINER_STOP_TIMEOUT" do
    ENV["PROUTERD_CONTAINER_STOP_TIMEOUT"] = "42"
    container = double("container")
    expect(container).to receive(:stop).with("t" => 42)
    described_class.force_stop(container)
  ensure
    ENV.delete("PROUTERD_CONTAINER_STOP_TIMEOUT")
  end

  it "falls back to kill when stop raises" do
    container = double("container")
    allow(container).to receive(:stop).and_raise(StandardError, "stop failed")
    expect(container).to receive(:kill)
    described_class.force_stop(container)
  end

  it "swallows kill errors silently" do
    container = double("container")
    allow(container).to receive(:stop).and_raise(StandardError)
    allow(container).to receive(:kill).and_raise(StandardError, "kill failed too")
    expect { described_class.force_stop(container) }.not_to raise_error
  end
end
