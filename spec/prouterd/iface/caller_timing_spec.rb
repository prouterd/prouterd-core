require "spec_helper"

RSpec.describe Prouterd::Iface::CallerTiming do
  let(:caller_class) do
    Class.new do
      include Prouterd::Iface::CallerTiming

      attr_accessor :next_result, :sleep_ms

      def initialize(result, sleep_ms: 0)
        @next_result = result
        @sleep_ms = sleep_ms
      end

      private

      def perform_run(_request)
        sleep(@sleep_ms / 1000.0) if @sleep_ms.positive?
        @next_result
      end
    end
  end

  let(:request) { double(:request) }

  it "wraps a success Hash into an ExecutionResult with timing fields" do
    instance = caller_class.new({
      exit_code: 0, output_json: { "ok" => true },
      stdout: "out", stderr: "", error_type: nil, error_message: nil
    })

    result = instance.run(request)

    expect(result).to be_a(Prouterd::Runner::ExecutionResult)
    expect(result.exit_code).to eq(0)
    expect(result.output_json).to eq("ok" => true)
    expect(result.stdout).to eq("out")
    expect(result.error_type).to be_nil
    expect(result.duration_ms).to be >= 0
    expect(result.started_at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
    expect(result.finished_at).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
  end

  it "preserves error fields and forces nil output_json" do
    instance = caller_class.new({
      exit_code: nil, output_json: nil,
      stdout: "", stderr: "boom",
      error_type: "timeout", error_message: "deadline"
    })

    result = instance.run(request)
    expect(result.error_type).to eq("timeout")
    expect(result.error_message).to eq("deadline")
    expect(result.exit_code).to be_nil
    expect(result.output_json).to be_nil
    expect(result.success?).to be(false)
  end

  it "measures a non-trivial duration" do
    instance = caller_class.new(
      { exit_code: 0, output_json: {}, stdout: "", stderr: "",
        error_type: nil, error_message: nil },
      sleep_ms: 50
    )

    result = instance.run(request)
    expect(result.duration_ms).to be >= 40   # leave headroom for jitter
  end

  it "defaults artifacts to [] when not provided" do
    instance = caller_class.new({
      exit_code: 0, output_json: {},
      stdout: "", stderr: "", error_type: nil, error_message: nil
    })
    expect(instance.run(request).artifacts).to eq([])
  end

  it "passes artifacts through when present" do
    artifact = double(:artifact)
    instance = caller_class.new({
      exit_code: 0, output_json: {},
      stdout: "", stderr: "", error_type: nil, error_message: nil,
      artifacts: [artifact]
    })
    expect(instance.run(request).artifacts).to eq([artifact])
  end
end
