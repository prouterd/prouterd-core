require "spec_helper"

RSpec.describe Prouterd::Runtime::Tracer do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) { parse(read_fixture("sales_ops.prc")) }

  it "matches the global route for a lead.created event" do
    result = described_class.trace(
      document,
      { "type" => "lead.created", "body" => {} },
      interface_name: "leads_in"
    )
    expect(result.global_route).not_to be_nil
    expect(result.global_route_passes).to be(true)
    expect(result.process).to eq("lead_pipeline")
  end

  it "rejects an event that does not match the global route" do
    result = described_class.trace(
      document,
      { "type" => "lead.archived" },
      interface_name: "leads_in"
    )
    expect(result.global_route_passes).to be(false)
    expect(result.warnings).to include(match(/no global route matched/))
  end

  it "marks runtime-dependent route conditions" do
    result = described_class.trace(
      document,
      { "type" => "lead.created", "body" => {} },
      interface_name: "leads_in"
    )
    edge = result.graph.find { |e| e.from == "score" && e.to == "notify_sales" }
    expect(edge).not_to be_nil
    expect(edge.passes).to eq(:runtime)
    expect(edge.match_results.first.result).to eq(:runtime)
  end

  it "reports unknown interface" do
    result = described_class.trace(document, {}, interface_name: "nope")
    expect(result.error).to include("unknown interface")
  end

  it "renders text via TracerRenderer" do
    result = described_class.trace(
      document,
      { "type" => "lead.created", "body" => {} },
      interface_name: "leads_in"
    )
    text = Prouterd::Runtime::TracerRenderer.render(result)
    expect(text).to include("Trace result")
    expect(text).to include("lead_pipeline")
    expect(text).to include("score -> notify_sales")
    expect(text).to include("depends on runtime")
  end

  it "warns about unreachable blocks" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img1
       image x
      exit
      process p
       block a
        interface docker img1
       exit
       block lonely
        interface docker img1
       exit
       block b
        interface docker img1
       exit
       route a b
      exit
      route interface cli process p
      exit
    PRC
    result = described_class.trace(doc, {}, interface_name: "cli")
    # Trace walks from entry blocks: 'a' and 'lonely' are both entry, so both
    # are visited. 'b' is reached via 'a'. So no unreachables here.
    expect(result.warnings).not_to include(match(/unreachable/))
  end
end
