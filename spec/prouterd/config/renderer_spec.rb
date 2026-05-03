require "spec_helper"

RSpec.describe Prouterd::Config::Renderer do
  def parse(src)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  def render(src)
    described_class.render(parse(src))
  end

  it "renders a router section" do
    out = render(<<~SRC)
      router demo
       version 1
       hostname host01
      exit
    SRC
    expect(out).to eq(<<~OUT)
      router demo
       version 1
       hostname host01
      exit
    OUT
  end

  it "quotes strings with whitespace in description" do
    out = render(<<~SRC)
      process p
       description "Lead enrichment"
       block a
        image x
       exit
      exit
    SRC
    expect(out).to include('description "Lead enrichment"')
  end

  it "renders match values: numbers unquoted, strings quoted" do
    out = render(<<~SRC)
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       route a b
        match lead.score gt 70
       exit
       route a b
        match event.type eq "lead.created"
       exit
      exit
    SRC
    expect(out).to include("match lead.score gt 70")
    expect(out).to include('match event.type eq "lead.created"')
  end

  it "renders 'in' operator with comma list" do
    out = render(<<~SRC)
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       route a b
        match lead.region in "US","EU","KZ"
       exit
      exit
    SRC
    expect(out).to include('match lead.region in "US","EU","KZ"')
  end

  it "renders 'exists' operator without value" do
    out = render(<<~SRC)
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       route a b
        match lead.email exists
       exit
      exit
    SRC
    expect(out).to include("match lead.email exists")
  end

  it "renders short-form route when no body fields are set" do
    out = render(<<~SRC)
      process p
       block a
        image x
       exit
       block b
        image y
       exit
       route a b
      exit
    SRC
    # short-form has no body
    expect(out).to include("route a b")
    expect(out).not_to include("route a b\n exit")
  end

  it "preserves duration canonical form" do
    out = render(<<~SRC)
      policy r
       retry initial-delay 5s
       retry max-delay 120s
       timeout 600s
      exit
    SRC
    expect(out).to include("retry initial-delay 5s")
    expect(out).to include("retry max-delay 2m")
    expect(out).to include("timeout 10m")
  end

  describe "roundtrip" do
    it "parse -> render -> parse yields equivalent AST for sales_ops fixture" do
      original_doc = parse(read_fixture("sales_ops.prc"))
      rendered = described_class.render(original_doc)
      reparsed_doc = parse(rendered)

      # Compare key invariants:
      expect(reparsed_doc.router.name).to eq(original_doc.router.name)
      expect(reparsed_doc.router.version).to eq(original_doc.router.version)
      expect(reparsed_doc.secrets.map(&:name)).to eq(original_doc.secrets.map(&:name))
      expect(reparsed_doc.policies.map(&:name)).to eq(original_doc.policies.map(&:name))
      expect(reparsed_doc.queues.map(&:name)).to eq(original_doc.queues.map(&:name))
      expect(reparsed_doc.interfaces.map(&:name)).to eq(original_doc.interfaces.map(&:name))
      expect(reparsed_doc.processes.length).to eq(original_doc.processes.length)

      orig_process = original_doc.processes.first
      reparsed_process = reparsed_doc.processes.first
      expect(reparsed_process.blocks.map(&:name)).to eq(orig_process.blocks.map(&:name))
      expect(reparsed_process.blocks.map(&:image)).to eq(orig_process.blocks.map(&:image))
      expect(reparsed_process.routes.length).to eq(orig_process.routes.length)

      reparsed_routes = reparsed_process.routes.map { |r| [r.from_block, r.to_block] }
      orig_routes = orig_process.routes.map { |r| [r.from_block, r.to_block] }
      expect(reparsed_routes).to eq(orig_routes)

      conditional = reparsed_process.routes.find { |r| !r.matches.empty? }
      expect(conditional).not_to be_nil
      expect(conditional.matches.first.path).to eq("lead.scored.score")
      expect(conditional.matches.first.operator).to eq("gt")
      expect(conditional.matches.first.values).to eq([70])
    end

    it "is idempotent: render(parse(render(parse(x)))) == render(parse(x))" do
      first = described_class.render(parse(read_fixture("sales_ops.prc")))
      second = described_class.render(parse(first))
      expect(second).to eq(first)
    end
  end

  describe "artifacts" do
    it "roundtrips produces and `input from` verbatim" do
      src = <<~SRC
        router demo
        exit

        process p
         no shutdown

         block train
          type docker
           image trainer:v1
          exit
          produces model.pkl
          produces metrics.json
          enable
         exit

         block deploy
          type docker
           image deploy:v1
          exit
          input event.body
          input from train.model.pkl
          input from train.metrics.json
          enable
         exit

         route train deploy
        exit
      SRC
      first = described_class.render(parse(src))
      second = described_class.render(parse(first))
      expect(second).to eq(first)
      expect(first).to include("produces model.pkl")
      expect(first).to include("input from train.model.pkl")
      expect(first).to include("input from train.metrics.json")
    end
  end
end
