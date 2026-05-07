require "spec_helper"

RSpec.describe Prouterd::Config::Renderer do
  RENDERER_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
    interface docker img2
     image alpine:2
    exit
  PRC

  def parse(src)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  def render_with_ifaces(src)
    described_class.render(parse(RENDERER_IFACES + src))
  end

  it "renders a router section" do
    out = described_class.render(parse(<<~SRC))
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
    out = render_with_ifaces(<<~SRC)
      process p
       description "Lead enrichment"
       block a
        interface docker img1
       exit
      exit
    SRC
    expect(out).to include('description "Lead enrichment"')
  end

  it "renders match values: numbers unquoted, strings quoted" do
    out = render_with_ifaces(<<~SRC)
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img2
       exit
       route a b
        match lead.score gt 70
       exit
      exit
    SRC
    expect(out).to include("match lead.score gt 70")
  end

  it "renders 'in' operator with comma list" do
    out = render_with_ifaces(<<~SRC)
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img2
       exit
       route a b
        match lead.region in "US","EU","KZ"
       exit
      exit
    SRC
    expect(out).to include('match lead.region in "US","EU","KZ"')
  end

  it "renders 'exists' operator without value" do
    out = render_with_ifaces(<<~SRC)
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img2
       exit
       route a b
        match lead.email exists
       exit
      exit
    SRC
    expect(out).to include("match lead.email exists")
  end

  it "renders short-form route when no body fields are set" do
    out = render_with_ifaces(<<~SRC)
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img2
       exit
       route a b
      exit
    SRC
    expect(out).to include("route a b")
    expect(out).not_to include("route a b\n exit")
  end

  it "preserves duration canonical form" do
    out = described_class.render(parse(<<~SRC))
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
      orig_refs = orig_process.blocks.map { |b| b.interface_ref&.name }
      reparsed_refs = reparsed_process.blocks.map { |b| b.interface_ref&.name }
      expect(reparsed_refs).to eq(orig_refs)
      expect(reparsed_process.routes.length).to eq(orig_process.routes.length)

      reparsed_routes = reparsed_process.routes.map { |r| [r.from_block, r.to_block] }
      orig_routes = orig_process.routes.map { |r| [r.from_block, r.to_block] }
      expect(reparsed_routes).to eq(orig_routes)

      conditional = reparsed_process.routes.find { |r| !r.matches.empty? }
      expect(conditional).not_to be_nil
      expect(conditional.matches.first.path).to eq("score.score")
      expect(conditional.matches.first.operator).to eq("gt")
      expect(conditional.matches.first.values).to eq([70])
    end

    it "is idempotent: render(parse(render(parse(x)))) == render(parse(x))" do
      first = described_class.render(parse(read_fixture("sales_ops.prc")))
      second = described_class.render(parse(first))
      expect(second).to eq(first)
    end

    it "round-trips a policy with retry feedback directives" do
      src = <<~SRC
        policy reflect
         retry attempts 3
         retry backoff fixed
         retry when output.verify eq "fail"
         retry feedback output.verify.notes into feedback
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("retry feedback output.verify.notes into feedback")
      reparsed = parse(first)
      fbs = reparsed.policies.first.retry_feedbacks
      expect(fbs.length).to eq(1)
      expect(fbs.first.from).to eq("output.verify.notes")
      expect(fbs.first.into).to eq("feedback")
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "round-trips a pause block" do
      src = <<~SRC
        process p
         block approve
          pause "ok?"
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("pause \"ok?\"")
      reparsed = parse(first)
      expect(reparsed.processes.first.blocks.first.pause_reason).to eq("ok?")
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "round-trips a `parallel` group (children inside, no synthesized noise)" do
      src = <<~SRC
        interface docker img1
         image alpine:1
        exit
        process p
         parallel evidence
          join-strategy all-best-effort
          block a
           interface docker img1
          exit
          block b
           interface docker img1
          exit
         exit

         block downstream
          interface docker img1
         exit

         route evidence downstream
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("parallel evidence")
      expect(first).to include("join-strategy all-best-effort")
      # Synthesized routes (a -> evidence, b -> evidence) must NOT
      # surface in the rendered output — only the user-written
      # `route evidence downstream` and the `parallel` section.
      expect(first).not_to match(/route a evidence/)
      expect(first).not_to match(/route b evidence/)
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "round-trips a `tool` declaration and a block with `agentic on`" do
      src = <<~SRC
        interface http jira
         base-url "https://x"
        exit
        interface llm m
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
        tool jira_search
         description "Search issues."
         args jql, max
         returns issues
         implementation interface http jira call get
        exit
        process p
         block deep_dive
          interface llm m
          prompt "ping"
          agentic on
          allowed-tools jira_search
          tool-call-limit 8
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("tool jira_search")
      expect(first).to include("agentic on")
      expect(first).to include("allowed-tools jira_search")
      expect(first).to include("tool-call-limit 8")
      expect(described_class.render(parse(first))).to eq(first)
    end

    it "round-trips block-level fan-out" do
      src = <<~SRC
        interface docker img1
         image alpine:1
        exit
        process poller
         block search
          interface docker img1
          fan-out from issues into analyze
         exit
        exit
        process analyze
         block a
          interface docker img1
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("fan-out from issues into analyze")
      reparsed = parse(first)
      expect(reparsed.processes.first.blocks.first.fan_out_into).to eq("analyze")
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "round-trips process thread-id template" do
      src = <<~SRC
        interface docker img1
         image alpine:1
        exit
        process per_ticket
         thread-id "{{event.ticket}}"
         no shutdown
         block b
          interface docker img1
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("thread-id \"{{event.ticket}}\"")
      reparsed = parse(first)
      expect(reparsed.processes.first.thread_id_template).to eq("{{event.ticket}}")
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "round-trips a vars sub-section on a block" do
      src = <<~SRC
        interface docker img1
         image alpine:1
        exit
        process p
         block b
          interface docker img1
          vars
           evidence "{{event.body.evidence}}"
           lim "10"
          exit
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("vars\n")
      expect(first).to include("  evidence \"{{event.body.evidence}}\"")
      expect(first).to include("  lim \"10\"")
      reparsed = parse(first)
      expect(reparsed.processes.first.blocks.first.vars).to eq(
        "evidence" => "{{event.body.evidence}}",
        "lim" => "10"
      )
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "round-trips skip-when on a block" do
      src = <<~SRC
        interface docker img1
         image alpine:1
        exit
        process p
         block b
          interface docker img1
          skip-when event.kind eq "noop"
         exit
        exit
      SRC
      first = described_class.render(parse(src))
      expect(first).to include("skip-when event.kind eq \"noop\"")
      reparsed = parse(first)
      block = reparsed.processes.first.blocks.first
      expect(block.skip_when.path).to eq("event.kind")
      expect(block.skip_when.values).to eq(["noop"])
      expect(described_class.render(reparsed)).to eq(first)
    end

    it "preserves multi-line :command call-fields across render -> parse" do
      require "tmpdir"
      tmpdir = Dir.mktmpdir("prc-multiline-")
      begin
        File.write(File.join(tmpdir, "sys.md"), "Line 1\nLine 2\twith tab\n")

        src = <<~SRC
          interface llm chat
           provider anthropic
           model claude-haiku-4-5-20251001
          exit
          process p
           block summarize
            interface llm chat
            system file "sys.md"
            prompt "ping"
           exit
          exit
        SRC

        doc = Prouterd::Config::Parser.parse(
          Prouterd::Config::Lexer.tokenize(src),
          base_dir: tmpdir
        )
        rendered = described_class.render(doc)
        # Round-trip via the rendered (no base_dir) form must work.
        reparsed = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(rendered))

        original_block = doc.processes.first.blocks.first
        reparsed_block = reparsed.processes.first.blocks.first
        expect(reparsed_block.type_fields["system"]).to eq(original_block.type_fields["system"])
        expect(reparsed_block.type_fields["system"]).to eq("Line 1\nLine 2\twith tab\n")
      ensure
        FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
      end
    end
  end

  describe "artifacts" do
    it "roundtrips produces and `input from` verbatim" do
      src = <<~SRC
        router demo
        exit

        interface docker trainer
         image trainer:v1
        exit

        interface docker deploy_img
         image deploy:v1
        exit

        process p
         no shutdown

         block train
          interface docker trainer
          produces model.pkl
          produces metrics.json
          enable
         exit

         block deploy
          interface docker deploy_img
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
