require "spec_helper"

RSpec.describe Prouterd::Config::Validator do
  def validate(src)
    lines = Prouterd::Config::Lexer.tokenize(src)
    doc = Prouterd::Config::Parser.parse(lines)
    [doc, described_class.validate(doc)]
  end

  it "accepts the canonical sales_ops fixture" do
    _, result = validate(read_fixture("sales_ops.prc"))
    expect(result.errors).to be_empty
    expect(result.valid?).to be(true)
  end

  it "accepts the minimal fixture" do
    _, result = validate(read_fixture("minimal.prc"))
    expect(result.errors).to be_empty
  end

  it "errors when router is missing" do
    _, result = validate(<<~SRC)
      queue default
       concurrency 1
       timeout 1m
      exit
    SRC
    expect(result.errors.map(&:message)).to include(match(/missing 'router'/))
  end

  it "detects unknown secret reference in webhook auth" do
    _, result = validate(<<~SRC)
      router x
      exit
      interface webhook leads_in
       path /leads
       method POST
       auth bearer secret MISSING_TOKEN
       no shutdown
      exit
    SRC
    expect(result.errors.map(&:message)).to include(match(/unknown secret 'MISSING_TOKEN'/))
  end

  it "detects unknown queue reference" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       queue ghost
       block a
        image x
       exit
      exit
    SRC
    expect(result.errors.map(&:message)).to include(match(/unknown queue 'ghost'/))
  end

  it "detects unknown retry policy reference" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
        retry policy nonexistent
       exit
      exit
    SRC
    expect(result.errors.map(&:message)).to include(match(/unknown policy 'nonexistent'/))
  end

  it "detects cycles in process graph" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       route a b
       route b a
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/contains a cycle/)
  end

  it "detects multiple incoming routes" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       block c
        image z
       exit
       route a c
       route b c
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/multiple incoming routes/)
  end

  it "detects self-loop routes" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
       route a a
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/self-loop/)
  end

  it "detects missing image" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
       exit
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/missing 'image'/)
  end

  it "detects unknown block in route" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
       route a ghost
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/unknown to-block 'ghost'/)
  end

  it "detects unknown interface in global route" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
      exit
      route interface ghost process p
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/unknown interface 'ghost'/)
  end

  it "treats blocks with no incoming routes as parallel entry points (no warning)" do
    # Multiple entry blocks are valid in MVP — they run in parallel. The
    # unreachable-warning code path is reserved for future graph topologies
    # where unreachable subgraphs become possible (e.g. once join semantics
    # are added).
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
       block lonely
        image y
       exit
       block z
        image z
       exit
       route a z
      exit
    SRC
    expect(result.errors).to be_empty
    expect(result.warnings.map(&:message).join("\n")).not_to match(/unreachable/)
  end

  it "detects duplicate processes" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        image x
       exit
      exit
      process p
       block b
        image y
       exit
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/duplicate process 'p'/)
  end
end
