require "spec_helper"

RSpec.describe Prouterd::Runtime::Context do
  it "starts empty" do
    expect(described_class.new.to_h).to eq({})
  end

  it "seeds from a hash" do
    ctx = described_class.new("event" => { "type" => "lead.created" })
    expect(ctx.get("event.type")).to eq("lead.created")
  end

  it "get returns nil for missing path" do
    ctx = described_class.new
    expect(ctx.get("foo.bar.baz")).to be_nil
  end

  it "get returns nil if a hop is non-Hash" do
    ctx = described_class.new("event" => "not-a-hash")
    expect(ctx.get("event.type")).to be_nil
  end

  it "set creates intermediate hashes" do
    ctx = described_class.new
    ctx.set("lead.scored.score", 87)
    expect(ctx.get("lead.scored.score")).to eq(87)
    expect(ctx.to_h).to eq("lead" => { "scored" => { "score" => 87 } })
  end

  it "set overwrites existing leaf" do
    ctx = described_class.new("a" => "old")
    ctx.set("a", "new")
    expect(ctx.get("a")).to eq("new")
  end

  it "set raises when an intermediate hop is non-Hash" do
    ctx = described_class.new("a" => "scalar")
    expect { ctx.set("a.b", 1) }.to raise_error(TypeError, /collides/)
  end

  it "to_h returns a deep copy" do
    ctx = described_class.new("nested" => { "x" => 1 })
    snapshot = ctx.to_h
    ctx.set("nested.x", 2)
    expect(snapshot["nested"]["x"]).to eq(1)
  end

  it "stringifies keys for consistency" do
    ctx = described_class.new(event: { type: "foo" })
    expect(ctx.get("event.type")).to eq("foo")
  end
end
