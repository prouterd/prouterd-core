require "spec_helper"

# Targets the `set(path, value)` branch where an intermediate hop is
# already a Hash so the auto-create-Hash else doesn't fire — exercising
# the third path through `parts.each` (existing Hash, no replacement).
RSpec.describe Prouterd::Runtime::Context do
  it "walks through pre-existing Hash hops without overwriting them" do
    ctx = described_class.new("a" => { "b" => { "preexisting" => true } })
    ctx.set("a.b.c", 42)

    expect(ctx.get("a.b.preexisting")).to be(true)
    expect(ctx.get("a.b.c")).to eq(42)
  end
end
