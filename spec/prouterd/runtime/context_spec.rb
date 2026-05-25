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

  it "get with a nil or empty path returns the whole tree" do
    ctx = described_class.new("a" => 1)
    expect(ctx.get(nil)).to eq("a" => 1)
    expect(ctx.get("")).to eq("a" => 1)
  end

  it "get walks Array indices via numeric string path segments" do
    ctx = described_class.new("xs" => [{ "v" => 10 }, { "v" => 20 }])
    expect(ctx.get("xs.1.v")).to eq(20)
  end

  it "set raises when the path is nil or empty" do
    ctx = described_class.new
    expect { ctx.set(nil, 1) }.to raise_error(ArgumentError, /non-empty/)
    expect { ctx.set("",  1) }.to raise_error(ArgumentError, /non-empty/)
  end

  it "merge_into overwrites when the existing value is non-Hash" do
    ctx = described_class.new("a" => "scalar")
    ctx.merge_into("a", { "k" => "v" })
    expect(ctx.get("a")).to eq("k" => "v")
  end

  it "merge_into hash-merges when both existing and incoming are Hashes" do
    ctx = described_class.new("a" => { "k1" => "v1" })
    ctx.merge_into("a", { "k2" => "v2" })
    expect(ctx.get("a")).to eq("k1" => "v1", "k2" => "v2")
  end

  it "merge_into overwrites when the incoming value is non-Hash" do
    ctx = described_class.new("a" => { "k" => "v" })
    ctx.merge_into("a", "scalar")
    expect(ctx.get("a")).to eq("scalar")
  end

  it "to_h deep-dups Arrays as well as Hashes" do
    ctx = described_class.new("xs" => [{ "v" => 1 }])
    snap = ctx.to_h
    ctx.get("xs").first["v"] = 99
    # snap['xs'] keys are stringified during deep_dup; ensure independence
    expect(snap["xs"].first["v"]).to eq(1)
  end
end
