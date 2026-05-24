require "spec_helper"

RSpec.describe "merge <name> parser + renderer" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:src) do
    <<~PRC
      router demo
      exit
      interface docker img1
       image x
      exit
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img1
       exit
       block c
        interface docker img1
       exit

       merge final
        from a, b, c
        strategy all-best-effort
       exit
      exit
    PRC
  end

  it "parses members from a comma-separated `from` line" do
    doc = parse(src)
    process = doc.processes.first
    expect(process.merge_groups.length).to eq(1)
    group = process.merge_groups.first
    expect(group.name).to eq("final")
    expect(group.strategy).to eq("all-best-effort")
    expect(group.member_block_names).to eq(%w[a b c])
  end

  it "synthesizes a barrier block of kind :merge with the right strategy" do
    doc = parse(src)
    process = doc.processes.first
    barrier = process.block("final")
    expect(barrier).not_to be_nil
    expect(barrier.barrier?).to be(true)
    expect(barrier.barrier_kind).to eq(:merge)
    expect(barrier.barrier_join_strategy).to eq("all-best-effort")
    expect(barrier.barrier_for).to eq(%w[a b c])
  end

  it "synthesizes member→barrier routes with on_failure=continue for non-required" do
    doc = parse(src)
    process = doc.processes.first
    routes = process.routes.select { |r| r.to_block == "final" }
    expect(routes.map(&:from_block)).to eq(%w[a b c])
    routes.each { |r| expect(r.on_failure).to eq("continue") }
  end

  it "all-required keeps on_failure=stop on synthesized routes" do
    doc = parse(src.sub("all-best-effort", "all-required"))
    process = doc.processes.first
    process.routes.select { |r| r.to_block == "final" }.each do |r|
      expect(r.on_failure).to eq("stop")
    end
  end

  it "rejects an empty `from` list" do
    expect {
      parse(<<~PRC)
        router demo
        exit
        process p
         block a
          interface docker x
         exit
         merge final
          strategy any
         exit
        exit
      PRC
    }.to raise_error(Prouterd::Config::ParseError, /must list at least one member/)
  end

  it "rejects unknown strategy" do
    expect {
      parse(src.sub("all-best-effort", "first-wins"))
    }.to raise_error(Prouterd::Config::ParseError, /invalid strategy 'first-wins'/)
  end

  it "rejects duplicate members" do
    expect {
      parse(src.sub("from a, b, c", "from a, b, a"))
    }.to raise_error(Prouterd::Config::ParseError, /duplicate member 'a'/)
  end

  it "rejects a merge name that collides with an existing block" do
    expect {
      parse(<<~PRC)
        router demo
        exit
        process p
         block dup
          interface docker x
         exit
         merge dup
          from dup
          strategy any
         exit
        exit
      PRC
    }.to raise_error(Prouterd::Config::ParseError, /name 'dup' is already declared/)
  end

  it "validator rejects unknown members" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image x
      exit
      process p
       block a
        interface docker img1
       exit

       merge mix
        from a, ghost
        strategy all-required
       exit
      exit
    PRC

    result = Prouterd::Config::Validator.validate(doc)
    expect(result.errors.map(&:message).join("\n")).to match(/unknown member block 'ghost'/)
  end

  it "renders parse->render roundtrip identically" do
    first  = Prouterd::Config::Renderer.render(parse(src))
    second = Prouterd::Config::Renderer.render(parse(first))
    expect(second).to eq(first)
    expect(first).to include("merge final")
    expect(first).to include("from a, b, c")
    expect(first).to include("strategy all-best-effort")
  end

  it "omits the strategy line when it's the default all-required" do
    doc = parse(src.sub("strategy all-best-effort\n", ""))
    rendered = Prouterd::Config::Renderer.render(doc)
    expect(rendered).to include("merge final")
    expect(rendered).to include("from a, b, c")
    expect(rendered).not_to include("strategy all-required")
  end
end
