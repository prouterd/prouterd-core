require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Logger do
  let(:io) { StringIO.new }
  let(:log) { described_class.build(io, level: "debug") }

  it "writes a single line per call with timestamp + level + message" do
    log.info("hello")
    line = io.string
    expect(line).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z INFO {2}prouterd: hello\n\z/)
  end

  it "renders kv-pairs after the message" do
    log.warn("worker stalled", worker: "w-01", run_id: "run_123", attempts: 3)
    expect(io.string).to include("worker stalled worker=w-01 run_id=run_123 attempts=3")
  end

  it "quotes values containing spaces or =" do
    log.info("x", path: "/tmp/with space", expr: "a=b")
    expect(io.string).to include("path=\"/tmp/with space\"")
    expect(io.string).to include("expr=\"a=b\"")
  end

  it "honors level — debug suppressed at info" do
    quiet = described_class.build(io, level: "info")
    quiet.debug("hidden")
    quiet.info("shown")
    expect(io.string).not_to include("hidden")
    expect(io.string).to include("shown")
  end

  it "with(...) merges baseline context into every call" do
    sub = log.with(run_id: "run_42")
    sub.info("started")
    sub.error("crashed", reason: "oom")
    expect(io.string).to include("started run_id=run_42")
    expect(io.string).to include("crashed run_id=run_42 reason=oom")
  end

  it "NullLogger is a no-op safe to call" do
    n = Prouterd::NullLogger.new
    expect { n.info("x", k: 1); n.with(k: 1).warn("y") }.not_to raise_error
  end

  it "PROUTERD_LOG_LEVEL env controls default level" do
    ENV["PROUTERD_LOG_LEVEL"] = "warn"
    quiet = described_class.build(io)
    quiet.info("not shown")
    quiet.warn("shown")
    expect(io.string).not_to include("not shown")
    expect(io.string).to include("shown")
  ensure
    ENV.delete("PROUTERD_LOG_LEVEL")
  end
end
