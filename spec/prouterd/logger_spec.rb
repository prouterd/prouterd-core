require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Logger do
  let(:io) { StringIO.new }
  let(:log) { described_class.build(io, level: "debug") }

  it "writes a single syslog-style line per call: <ts>: %<FAC>-<SEV>-<MNEMO>: <msg>" do
    log.info("hello", facility: "TEST", mnemonic: "HELLO")
    line = io.string
    expect(line).to match(/\A\w{3} +\d{1,2} \d{2}:\d{2}:\d{2}\.\d{3}: %TEST-6-HELLO: hello\n\z/)
  end

  it "renders kv-pairs after the message" do
    log.warn("worker stalled", facility: "WORK", mnemonic: "STALL",
             worker: "w-01", run_id: "run_123", attempts: 3)
    expect(io.string).to include("%WORK-4-STALL: worker stalled worker=w-01 run_id=run_123 attempts=3")
  end

  it "quotes values containing spaces or =" do
    log.info("x", facility: "T", mnemonic: "Q", path: "/tmp/with space", expr: "a=b")
    expect(io.string).to include("path=\"/tmp/with space\"")
    expect(io.string).to include("expr=\"a=b\"")
  end

  it "honors level — debug suppressed at info" do
    quiet = described_class.build(io, level: "info")
    quiet.debug("hidden", facility: "T", mnemonic: "D")
    quiet.info("shown",   facility: "T", mnemonic: "I")
    expect(io.string).not_to include("hidden")
    expect(io.string).to include("shown")
  end

  it "with(...) merges baseline context into every call" do
    sub = log.with(run_id: "run_42")
    sub.info("started", facility: "RUN", mnemonic: "STARTED")
    sub.error("crashed", facility: "RUN", mnemonic: "CRASHED", reason: "oom")
    expect(io.string).to include("started run_id=run_42")
    expect(io.string).to include("crashed run_id=run_42 reason=oom")
  end

  it "appends every entry to the process-global ring buffer for `show logging`" do
    Prouterd::Logger.ring.tail(1000) # drain residue from earlier tests
    log.info("a", facility: "RUN", mnemonic: "A")
    log.warn("b", facility: "RUN", mnemonic: "B")
    rows = Prouterd::Logger.ring.tail(50, facility: "RUN")
    expect(rows.last(2).map { |e| e[:mnemonic] }).to eq(%w[A B])
    expect(rows.last(2).map { |e| e[:severity] }).to eq([6, 4])
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
