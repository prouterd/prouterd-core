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

  it "detects missing block type (block declares neither image nor exec)" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
       exit
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/missing 'type' section/)
  end

  it "detects missing image when block has type docker" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        type docker
        exit
       exit
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/\(type docker\) missing 'image'/)
  end

  it "detects missing exec when block has type shell" do
    _, result = validate(<<~SRC)
      router x
      exit
      process p
       block a
        type shell
        exit
       exit
      exit
    SRC
    expect(result.errors.map(&:message).join("\n")).to match(/\(type shell\) missing 'exec'/)
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

  describe "artifact flow" do
    def validate_pipeline(body)
      validate(<<~SRC)
        router x
        exit
        process p
        #{body.lines.map { |l| " #{l}" }.join}
        exit
      SRC
    end

    it "accepts well-formed produces/consume pair" do
      _, result = validate_pipeline(<<~BLOCKS)
        block train
         image t:1
         produces model.pkl
        exit
        block deploy
         image d:1
         input from train.model.pkl
        exit
        route train deploy
      BLOCKS
      expect(result.errors).to be_empty
    end

    it "errors when the upstream block does not exist" do
      _, result = validate_pipeline(<<~BLOCKS)
        block deploy
         image d:1
         input from ghost.model.pkl
        exit
      BLOCKS
      expect(result.errors.map(&:message).join("\n"))
        .to match(/references unknown block 'ghost'/)
    end

    it "errors when the upstream block does not declare the artifact" do
      _, result = validate_pipeline(<<~BLOCKS)
        block train
         image t:1
        exit
        block deploy
         image d:1
         input from train.model.pkl
        exit
        route train deploy
      BLOCKS
      expect(result.errors.map(&:message).join("\n"))
        .to match(/does not declare 'produces model.pkl'/)
    end

    it "errors when two inputs derive the same local name (basename collision)" do
      _, result = validate_pipeline(<<~BLOCKS)
        block train
         image t:1
         produces model.pkl
         produces model.json
        exit
        block deploy
         image d:1
         input from train.model.pkl
         input from train.model.json
        exit
        route train deploy
      BLOCKS
      expect(result.errors.map(&:message).join("\n"))
        .to match(/both derive local name 'model'/)
    end

    it "errors when the upstream is not reachable in the route graph" do
      _, result = validate_pipeline(<<~BLOCKS)
        block train
         image t:1
         produces model.pkl
        exit
        block other
         image o:1
        exit
        block deploy
         image d:1
         input from train.model.pkl
        exit
        route other deploy
      BLOCKS
      expect(result.errors.map(&:message).join("\n"))
        .to match(/'train' is not upstream/)
    end
  end
end
