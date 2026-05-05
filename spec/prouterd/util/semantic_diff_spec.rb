require "spec_helper"

# Phase 36e: Util::SemanticDiff. Pure data — given two parsed AST::Documents,
# produce a structural diff (added/removed/changed) per section type.
RSpec.describe Prouterd::Util::SemanticDiff do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:base) do
    parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
        exec "true"
       exit
      exit
      route interface cli process p
      exit
    PRC
  end

  it "reports an empty diff for the same document" do
    result = described_class.diff(base, base)
    expect(result).to be_empty
    expect(result.total).to eq(0)
  end

  it "detects an added process" do
    candidate = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
        exec "true"
       exit
      exit
      process q
       block b
        interface shell host
        exec "true"
       exit
      exit
      route interface cli process p
      exit
    PRC

    result = described_class.diff(base, candidate)
    expect(result.processes_added.map(&:name)).to eq(["q"])
    expect(result.processes_removed).to be_empty
  end

  it "detects a changed block within an existing process" do
    candidate = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
        exec "true"
        timeout 30s
       exit
      exit
      route interface cli process p
      exit
    PRC

    result = described_class.diff(base, candidate)
    expect(result.processes_changed.map(&:name)).to eq(["p"])
    expect(result.processes_added).to be_empty
  end

  it "detects an added route" do
    candidate = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface webhook hook
       path /x
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
        exec "true"
       exit
      exit
      route interface cli process p
      exit
      route interface hook process p
      exit
    PRC

    result = described_class.diff(base, candidate)
    expect(result.interfaces_added.map(&:name)).to eq(["hook"])
    expect(result.routes_added.map(&:name)).to eq(["hook->p"])
  end

  it "detects a changed policy" do
    base_with_policy = parse(<<~PRC)
      router demo
      exit
      policy r
       retry attempts 2
       retry backoff fixed
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
       exit
      exit
      route interface cli process p
      exit
    PRC

    bumped = parse(base_with_policy.processes.first ? <<~PRC : "")
      router demo
      exit
      policy r
       retry attempts 5
       retry backoff exponential
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
       exit
      exit
      route interface cli process p
      exit
    PRC

    result = described_class.diff(base_with_policy, bumped)
    expect(result.policies_changed.map(&:name)).to eq(["r"])
  end
end
