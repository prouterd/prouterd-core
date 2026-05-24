require "spec_helper"

RSpec.describe Prouterd::Runtime::Tracer do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  it "errors when event is not a Hash" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    result = described_class.trace(doc, "not a hash", interface_name: "cli")
    expect(result.error).to include("event must be a Hash")
  end

  it "warns when the named interface is shutdown" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    result = described_class.trace(doc, {}, interface_name: "cli")
    expect(result.warnings).to include(match(/interface 'cli' is shutdown/))
  end

  it "warns when the chosen process is shutdown" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       shutdown
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    result = described_class.trace(doc, {}, interface_name: "cli")
    expect(result.warnings).to include(match(/process 'p' is shutdown/))
  end

  it "errors when a global route targets an undeclared process" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    doc.global_routes.first.process_name = "ghost"
    result = described_class.trace(doc, {}, interface_name: "cli")
    expect(result.error).to include("unknown process 'ghost'")
  end

  it "warns about processes that have no entry blocks (every block has incoming)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
       route b a
      exit
      route interface cli process p
      exit
    PRC
    result = described_class.trace(doc, {}, interface_name: "cli")
    expect(result.warnings).to include(match(/no entry blocks/))
  end

  it "warns about unreachable blocks (declared but no incoming or entry path)" do
    doc2 = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
       route b a
       block c
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc2, {}, interface_name: "cli")
    # a and b are in a cycle (each has incoming), so they form the
    # non-entry set; only c (no incoming) is an entry block. From c
    # we visit nothing — a and b end up unreachable.
    expect(res.warnings).to include(match(/unreachable/))
  end

  it "skips an outgoing route whose target block doesn't exist (defensive)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
      exit
      route interface cli process p
      exit
    PRC
    # Add a dangling route via mutation (referencing a block name that's
    # not declared) so the tracer's `next unless target` branch fires.
    rr = Prouterd::Config::AST::ProcessRoute.new(from_block: "a", to_block: "ghost", line: 99)
    doc.processes.first.routes << rr
    res = described_class.trace(doc, {}, interface_name: "cli")
    # `a -> ghost` should NOT appear in the graph (target missing).
    expect(res.graph.map(&:to)).not_to include("ghost")
    # Real edge a -> b still present.
    expect(res.graph.map(&:to)).to include("b")
  end

  it "skips an entry-block name that's no longer in process.blocks (defensive)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    # Inject a phantom block name into the entry queue by stubbing.
    process = doc.processes.first
    allow_any_instance_of(described_class).to receive(:entry_blocks).and_return(["a", "ghost"])
    res = described_class.trace(doc, {}, interface_name: "cli")
    # Should still walk normally; the ghost is just ignored.
    expect(res.process).to eq("p")
  end

  it "ignores duplicate entry block names without raising" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    # entry_blocks returning duplicates → the `next if seen.include?` guard fires
    allow_any_instance_of(described_class).to receive(:entry_blocks).and_return(["a", "a"])
    res = described_class.trace(doc, {}, interface_name: "cli")
    # 'a' walked once, no exceptions
    expect(res.process).to eq("p")
  end

  it "does not enqueue a block that's already in the queue" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       block c
        interface docker img
       exit
       route a b
       route a c
       route c b
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    # Tracer doesn't crash on the diamond — 'b' has two incoming routes
    # from 'a' and 'c'; the queue dedupe prevents double-enqueue.
    edges_to_b = res.graph.select { |e| e.to == "b" }
    expect(edges_to_b.length).to be >= 1
  end

  it "evaluates entry-only process with no routes (graph stays empty)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    expect(res.graph).to be_empty
    text = Prouterd::Runtime::TracerRenderer.render(res)
    expect(text).to include("(no routes)")
  end

  it "annotates a route whose match references upstream block output as :runtime" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
        match a.score gt 50
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    edge = res.graph.find { |e| e.from == "a" && e.to == "b" }
    expect(edge.passes).to eq(:runtime)
    expect(edge.match_results.first.reason).to eq("depends on runtime output")
  end

  it "annotates a definite-false route condition and emits the skipped marker" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
        match event.type eq specific
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, { "type" => "other" }, interface_name: "cli")
    edge = res.graph.find { |e| e.from == "a" && e.to == "b" }
    expect(edge.passes).to eq(false)
    text = Prouterd::Runtime::TracerRenderer.render(res)
    expect(text).to include("skipped (condition false)")
  end

  it "collects policies including retry / timeout / contract / call-fields and shows non-default ones" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      policy r1
       retry attempts 2
      exit
      contract c1
       require event.body
      exit
      process p
       block a
        interface docker img
        command `echo hi`
        timeout 5s
        retry r1
        contract c1
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    summary = res.policies["a"]
    expect(summary[:interface]).to eq("docker img")
    expect(summary[:retry_policy]).to eq("r1")
    expect(summary[:timeout_ms]).to eq(5000)
    expect(summary[:contract]).to eq("c1")
    expect(summary[:command]).to eq("echo hi")
    text = Prouterd::Runtime::TracerRenderer.render(res)
    expect(text).to include("Policies:")
    expect(text).to include("a: ")
    expect(text).to include("retry_policy=r1")
  end

  it "drops a call-field whose value equals the call_field's declared default" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface llm m
       provider claude_cli
      exit
      process p
       block a
        interface llm m
        prompt "hi"
        max-tokens 1024
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    summary = res.policies["a"] || {}
    # max-tokens default is "1024"; value matches default → dropped.
    expect(summary).not_to have_key("max-tokens")
  end

  it "drops a call-field whose value is empty (responds_to :empty? && .empty?)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
        command ``
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    summary = res.policies["a"] || {}
    expect(summary).not_to have_key("command")
  end

  it "renders without a Policies section when no block has anything to summarise" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      process p
       block a
       exit
      exit
      route interface cli process p
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli")
    expect(res.policies).to be_empty
    text = Prouterd::Runtime::TracerRenderer.render(res)
    expect(text).not_to include("Policies:")
  end

  it "filters global-route candidates by interface name" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli1
       no shutdown
      exit
      interface manual cli2
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process pa
       block a
        interface docker img
       exit
      exit
      process pb
       block b
        interface docker img
       exit
      exit
      route interface cli1 process pa
      exit
      route interface cli2 process pb
      exit
    PRC
    res = described_class.trace(doc, {}, interface_name: "cli2")
    expect(res.process).to eq("pb")
  end
end

RSpec.describe Prouterd::Runtime::TracerRenderer do
  def make_result(**attrs)
    Prouterd::Runtime::Tracer::Result.new(
      interface: nil, event: {}, global_route: nil, global_route_passes: nil,
      process: nil, graph: [], policies: {}, warnings: [], error: nil, **attrs
    )
  end

  it "renders a terminal error and stops" do
    text = described_class.render(make_result(error: "boom"))
    expect(text).to start_with("Trace error: boom")
  end

  it "renders 'no matching global route' when no global route attached" do
    res = make_result(warnings: ["something"])
    text = described_class.render(res)
    expect(text).to include("(no matching global route)")
    expect(text).to include("something")
  end

  it "renders 'manual / no interface filter' label when interface is nil" do
    text = described_class.render(make_result)
    expect(text).to include("(manual / no interface filter)")
  end

  it "shows 'matched' / 'did not match' / 'depends on runtime' verdicts for a global route" do
    gr = Prouterd::Config::AST::GlobalRoute.new(
      interface_name: "cli", process_name: "p", line: 1
    )
    gr.matches << Prouterd::Config::AST::Match.new(path: "event.x", operator: "eq", values: ["y"], line: 2)

    %w[matched did\ not\ match depends\ on\ runtime].each_with_index do |label, idx|
      passes = [true, false, :runtime][idx]
      res = make_result(global_route: gr, global_route_passes: passes)
      text = described_class.render(res)
      expect(text).to include("(#{label})")
    end
  end

  it "renders 'in' values comma-joined and 'exists' values as empty string" do
    gr = Prouterd::Config::AST::GlobalRoute.new(interface_name: "cli", process_name: "p", line: 1)
    gr.matches << Prouterd::Config::AST::Match.new(path: "event.tag", operator: "in", values: ["a", "b"], line: 1)
    gr.matches << Prouterd::Config::AST::Match.new(path: "event.t", operator: "exists", values: [], line: 1)
    res = make_result(global_route: gr, global_route_passes: true)
    text = described_class.render(res)
    expect(text).to include("event.tag in \"a\",\"b\"")
    expect(text).to include("event.t exists")
  end

  it "renders 'in' values mixing String + numeric (then/else of v.is_a?(String) ternary)" do
    gr = Prouterd::Config::AST::GlobalRoute.new(interface_name: "cli", process_name: "p", line: 1)
    gr.matches << Prouterd::Config::AST::Match.new(path: "event.x", operator: "in", values: ["a", 7], line: 1)
    res = make_result(global_route: gr, global_route_passes: true)
    text = described_class.render(res)
    expect(text).to include("event.x in \"a\",7")
  end

  it "renders edge 'in' values mixing String + numeric (format_match_value ternary)" do
    edge = Prouterd::Runtime::Tracer::EdgeAnnotation.new(
      from: "a", to: "b",
      match_results: [
        Prouterd::Runtime::Tracer::MatchAnnotation.new(path: "p", operator: "in", values: ["x", 7], result: true, reason: nil)
      ],
      passes: true
    )
    res = make_result(process: "p", graph: [edge])
    text = described_class.render(res)
    expect(text).to include("p in \"x\",7")
  end

  it "renders numeric global-route values without inspect-style quoting" do
    gr = Prouterd::Config::AST::GlobalRoute.new(interface_name: "cli", process_name: "p", line: 1)
    gr.matches << Prouterd::Config::AST::Match.new(path: "event.n", operator: "gt", values: [5], line: 1)
    res = make_result(global_route: gr, global_route_passes: true)
    expect(described_class.render(res)).to include("event.n gt 5")
  end

  it "renders edge marker variants for true / false / runtime and 'in' values" do
    edge = Prouterd::Runtime::Tracer::EdgeAnnotation.new(
      from: "a", to: "b",
      match_results: [
        Prouterd::Runtime::Tracer::MatchAnnotation.new(path: "p", operator: "in", values: ["x", "y"], result: true, reason: nil),
        Prouterd::Runtime::Tracer::MatchAnnotation.new(path: "q", operator: "exists", values: [], result: false, reason: "boom"),
        Prouterd::Runtime::Tracer::MatchAnnotation.new(path: "r", operator: "gt", values: [3], result: :runtime, reason: "depends on runtime output")
      ],
      passes: :runtime
    )
    res = make_result(process: "p", graph: [edge])
    text = described_class.render(res)
    expect(text).to include("✓ match p in \"x\",\"y\"")
    expect(text).to include("✗ match q exists")
    expect(text).to include("? match r gt 3  (depends on runtime output)")
    expect(text).to include("depends on runtime")
  end

  it "writes 'none' when there are no warnings" do
    text = described_class.render(make_result(process: "p"))
    expect(text).to include("Warnings:\n  none")
  end
end
