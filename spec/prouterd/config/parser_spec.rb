require "spec_helper"

RSpec.describe Prouterd::Config::Parser do
  def parse(src)
    described_class.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  # Many block-side tests need an outbound interface to reference via
  # `interface docker <name>`. Helper prepends a minimal one so test
  # sources can focus on the block body / route shape under test.
  PARSER_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
    interface docker img2
     image alpine:2
    exit
  PRC

  def parse_with_ifaces(src)
    parse(PARSER_IFACES + src)
  end

  describe "router" do
    it "parses a router section with version and hostname" do
      doc = parse(<<~SRC)
        router demo
         version 1
         hostname prouter-01
        exit
      SRC
      expect(doc.router.name).to eq("demo")
      expect(doc.router.version).to eq(1)
      expect(doc.router.hostname).to eq("prouter-01")
    end

    it "rejects two routers" do
      expect do
        parse(<<~SRC)
          router a
          exit
          router b
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /already defined/)
    end

    it "rejects unknown directive in router" do
      expect do
        parse(<<~SRC)
          router demo
           color red
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /unknown directive 'color' in router/)
    end

    it "rejects missing exit" do
      expect do
        parse(<<~SRC)
          router demo
           version 1
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /missing 'exit'/)
    end
  end

  describe "secret" do
    it "parses env-sourced secrets" do
      doc = parse(<<~SRC)
        router x
        exit
        secret CLEARBIT_API_KEY
         source env CLEARBIT_API_KEY
        exit
      SRC
      secret = doc.secrets.first
      expect(secret.name).to eq("CLEARBIT_API_KEY")
      expect(secret.source_type).to eq("env")
      expect(secret.source_value).to eq("CLEARBIT_API_KEY")
    end

    it "rejects unsupported source kinds" do
      expect do
        parse(<<~SRC)
          secret X
           source vault path/key
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /unsupported secret source 'vault'/)
    end

    it "rejects lowercase secret names" do
      expect do
        parse(<<~SRC)
          secret lowercase_name
           source env X
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid secret name/)
    end
  end

  describe "policy" do
    it "parses retry policy fields" do
      doc = parse(<<~SRC)
        policy retry_standard
         retry attempts 3
         retry backoff exponential
         retry initial-delay 5s
         retry max-delay 2m
         timeout 30s
        exit
      SRC
      p = doc.policies.first
      expect(p.retry_attempts).to eq(3)
      expect(p.retry_backoff).to eq("exponential")
      expect(p.retry_initial_delay_ms).to eq(5_000)
      expect(p.retry_max_delay_ms).to eq(120_000)
      expect(p.timeout_ms).to eq(30_000)
    end

    it "rejects invalid backoff" do
      expect do
        parse(<<~SRC)
          policy p
           retry backoff weird
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid backoff 'weird'/)
    end

    it "parses `retry feedback <path> into <name>` directives" do
      doc = parse(<<~SRC)
        policy reflect
         retry attempts 3
         retry feedback output.verify.notes into feedback
         retry feedback output.score        into score
        exit
      SRC
      fbs = doc.policies.first.retry_feedbacks
      expect(fbs.length).to eq(2)
      expect(fbs.map(&:from)).to eq(%w[output.verify.notes output.score])
      expect(fbs.map(&:into)).to eq(%w[feedback score])
    end

    it "rejects `retry feedback` without an `into` clause" do
      expect do
        parse(<<~SRC)
          policy p
           retry feedback output.notes
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /retry feedback <output-path> into <local-name>/)
    end
  end

  describe "interface" do
    it "parses webhook interface" do
      doc = parse(<<~SRC)
        interface webhook leads_in
         path /leads
         method POST
         auth bearer secret WEBHOOK_TOKEN
         no shutdown
        exit
      SRC
      iface = doc.interfaces.first
      expect(iface.type).to eq("webhook")
      expect(iface.name).to eq("leads_in")
      expect(iface.type_fields["path"]).to eq("/leads")
      expect(iface.type_fields["method"]).to eq("POST")
      expect(iface.type_fields["auth"].scheme).to eq("bearer")
      expect(iface.type_fields["auth"].secret_name).to eq("WEBHOOK_TOKEN")
      expect(iface.shutdown).to be(false)
    end

    it "rejects path field on manual interface" do
      expect do
        parse(<<~SRC)
          interface manual cli
           path /foo
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /unknown directive 'path' in interface 'manual'/)
    end

    it "parses cron interface" do
      doc = parse(<<~SRC)
        interface cron daily
         schedule "0 9 * * *"
         timezone "Asia/Almaty"
         no shutdown
        exit
      SRC
      iface = doc.interfaces.first
      expect(iface.type_fields["schedule"]).to eq("0 9 * * *")
      expect(iface.type_fields["timezone"]).to eq("Asia/Almaty")
    end

    it "rejects invalid HTTP method" do
      expect do
        parse(<<~SRC)
          interface webhook x
           method WAVE
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid HTTP method 'WAVE'/)
    end
  end

  describe "process and blocks" do
    it "parses process with blocks and short-form routes" do
      doc = parse_with_ifaces(<<~SRC)
        process pipeline
         description "demo"
         queue default
         no shutdown

         block a
          interface docker img1
         exit
         block b
          interface docker img2
         exit

         route a b
        exit
      SRC
      process = doc.processes.first
      expect(process.name).to eq("pipeline")
      expect(process.description).to eq("demo")
      expect(process.queue_name).to eq("default")
      expect(process.blocks.map(&:name)).to eq(%w[a b])
      expect(process.routes.length).to eq(1)
      route = process.routes.first
      expect(route.from_block).to eq("a")
      expect(route.to_block).to eq("b")
      expect(route.matches).to be_empty
    end

    it "parses long-form route with match condition" do
      doc = parse_with_ifaces(<<~SRC)
        process pipeline
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
      route = doc.processes.first.routes.first
      expect(route.matches.length).to eq(1)
      m = route.matches.first
      expect(m.path).to eq("lead.score")
      expect(m.operator).to eq("gt")
      expect(m.values).to eq([70])
    end

    it "parses block with secrets, retry policy and command" do
      doc = parse_with_ifaces(<<~SRC)
        process p
         block enrich
          interface docker img1
          command "/bin/run --mode=safe"
          timeout 120s
          retry policy retry_standard
          secret CLEARBIT_API_KEY
          secret OTHER_KEY
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.interface_ref.type).to eq("docker")
      expect(block.interface_ref.name).to eq("img1")
      expect(block.type_fields["command"]).to eq("/bin/run --mode=safe")
      expect(block.timeout_ms).to eq(120_000)
      expect(block.retry_policy_name).to eq("retry_standard")
      expect(block.secret_names).to eq(%w[CLEARBIT_API_KEY OTHER_KEY])
    end

    it "rejects duplicate secret in same block" do
      expect do
        parse_with_ifaces(<<~SRC)
          process p
           block b
            interface docker img1
            secret K
            secret K
           exit
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /duplicate secret 'K'/)
    end
  end

  describe "match expressions" do
    it "parses 'in' operator with quoted values" do
      doc = parse(<<~SRC)
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
      m = doc.processes.first.routes.first.matches.first
      expect(m.operator).to eq("in")
      expect(m.values).to eq(%w[US EU KZ])
    end

    it "parses 'exists' operator with no values" do
      doc = parse(<<~SRC)
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
      m = doc.processes.first.routes.first.matches.first
      expect(m.operator).to eq("exists")
      expect(m.values).to be_empty
    end

    it "rejects unknown operator" do
      expect do
        parse_with_ifaces(<<~SRC)
          process p
           block a
            interface docker img1
           exit
           block b
            interface docker img2
           exit
           route a b
            match foo unknown 5
           exit
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /invalid match operator 'unknown'/)
    end
  end

  describe "global route" do
    it "parses interface -> process route with match" do
      doc = parse(<<~SRC)
        route interface leads_in process lead_pipeline
         match event.type eq "lead.created"
        exit
      SRC
      r = doc.global_routes.first
      expect(r.interface_name).to eq("leads_in")
      expect(r.process_name).to eq("lead_pipeline")
      expect(r.matches.first.operator).to eq("eq")
      expect(r.matches.first.values).to eq(["lead.created"])
    end

    it "rejects malformed global route" do
      expect do
        parse(<<~SRC)
          route iface leads_in process lead_pipeline
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /expected 'route interface/)
    end
  end

  describe "fixtures" do
    it "parses sales_ops.prc cleanly" do
      src = read_fixture("sales_ops.prc")
      doc = parse(src)
      expect(doc.router.name).to eq("sales_ops")
      expect(doc.secrets.map(&:name)).to eq(%w[WEBHOOK_TOKEN CLEARBIT_API_KEY])
      expect(doc.policies.map(&:name)).to eq(["retry_standard"])
      expect(doc.queues.map(&:name)).to eq(["default"])
      expect(doc.interfaces.map(&:name))
        .to contain_exactly("leads_in", "extractor", "enricher", "scorer", "notifier")
      expect(doc.processes.length).to eq(1)
      pipeline = doc.processes.first
      expect(pipeline.blocks.map(&:name)).to eq(%w[extract enrich score notify_sales])
      expect(pipeline.routes.length).to eq(3)
      expect(doc.global_routes.length).to eq(1)
    end

    it "parses a pause block (no interface dispatch)" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block approve
          pause "ok to ship?"
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.pause?).to be true
      expect(block.pause_reason).to eq("ok to ship?")
      expect(block.interface_ref).to be_nil
    end

    it "rejects mixing `pause` after `interface` on one block" do
      expect {
        parse_with_ifaces(<<~SRC)
          router x
          exit
          process p
           block b
            interface docker img1
            pause "huh"
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /pause` blocks have no interface dispatch/)
    end

    it "rejects mixing `interface` after `pause` on one block" do
      expect {
        parse_with_ifaces(<<~SRC)
          router x
          exit
          process p
           block b
            pause "huh"
            interface docker img1
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /cannot mix `pause` and `interface`/)
    end

    it "parses a `parallel` group, materialising children + a barrier + synthesized routes" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         parallel evidence
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
      process = doc.processes.first
      block_names = process.blocks.map(&:name)
      expect(block_names).to contain_exactly("a", "b", "evidence", "downstream")
      barrier = process.blocks.find { |b| b.name == "evidence" }
      expect(barrier.barrier?).to be true
      expect(barrier.barrier_for).to contain_exactly("a", "b")
      expect(barrier.barrier_join_strategy).to eq("all-required")
      members_to_barrier = process.routes.select { |r| r.to_block == "evidence" }
      expect(members_to_barrier.map(&:from_block)).to contain_exactly("a", "b")
      expect(members_to_barrier.map(&:on_failure).uniq).to eq(["stop"])
    end

    it "parses join-strategy all-best-effort and propagates on-failure=continue to synthesized routes" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         parallel g
          join-strategy all-best-effort
          block a
           interface docker img1
          exit
         exit
        exit
      SRC
      process = doc.processes.first
      barrier = process.blocks.find { |b| b.name == "g" }
      expect(barrier.barrier_join_strategy).to eq("all-best-effort")
      expect(process.routes.first.on_failure).to eq("continue")
    end

    it "rejects `parallel` whose body has no blocks" do
      expect {
        parse_with_ifaces(<<~SRC)
          router x
          exit
          process p
           parallel empty
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /must contain at least one block/)
    end

    it "parses a top-level `tool <name>` declaration" do
      doc = parse(<<~SRC)
        interface http jira
         base-url "https://x"
        exit
        tool jira_search
         description "Search Jira issues by JQL."
         args jql, max
         implementation interface http jira call get
        exit
      SRC
      tool = doc.tools.first
      expect(tool.name).to eq("jira_search")
      expect(tool.description).to eq("Search Jira issues by JQL.")
      expect(tool.args).to eq(%w[jql max])
      expect(tool.implementation.iface_type).to eq("http")
      expect(tool.implementation.iface_name).to eq("jira")
      expect(tool.implementation.call_name).to eq("get")
    end

    it "parses block-level agentic directives" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        interface llm m
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
        tool t
         args x
         implementation interface docker img1 call run
        exit
        process p
         block deep_dive
          interface llm m
          agentic on
          allowed-tools t
          tool-call-limit 5
          prompt "ping"
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.agentic).to be true
      expect(block.allowed_tools).to eq(%w[t])
      expect(block.tool_call_limit).to eq(5)
    end

    it "parses block-level fan-out directive" do
      doc = parse_with_ifaces(<<~SRC)
        router x
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
      block = doc.processes.first.blocks.first
      expect(block.fan_out?).to be true
      expect(block.fan_out_from).to eq("issues")
      expect(block.fan_out_into).to eq("analyze")
    end

    it "parses process thread-id template" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process per_ticket
         thread-id "{{event.ticket}}"
         block b
          interface docker img1
         exit
        exit
      SRC
      expect(doc.processes.first.thread_id_template).to eq("{{event.ticket}}")
    end

    it "parses minimal.prc cleanly" do
      doc = parse(read_fixture("minimal.prc"))
      expect(doc.router.name).to eq("demo")
      expect(doc.processes.first.blocks.first.type_fields["command"]).to eq("echo hello")
    end

    it "parses skip-when into a Match on the block" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block b
          interface docker img1
          skip-when event.flag eq "skip"
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.skip_when).not_to be_nil
      expect(block.skip_when.path).to eq("event.flag")
      expect(block.skip_when.operator).to eq("eq")
      expect(block.skip_when.values).to eq(["skip"])
    end

    it "rejects two skip-when directives on one block" do
      expect {
        parse_with_ifaces(<<~SRC)
          router x
          exit
          process p
           block b
            interface docker img1
            skip-when event.a eq 1
            skip-when event.b eq 2
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /already has a skip-when/)
    end

    it "parses a vars sub-section into a Hash<name, template>" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block b
          interface docker img1
          vars
           evidence  "{{event.body.evidence}}"
           iteration "{{previous.attempt}}"
          exit
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.vars).to eq(
        "evidence"  => "{{event.body.evidence}}",
        "iteration" => "{{previous.attempt}}"
      )
    end

    it "rejects a duplicate var name" do
      expect {
        parse_with_ifaces(<<~SRC)
          router x
          exit
          process p
           block b
            interface docker img1
            vars
             a "1"
             a "2"
            exit
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /duplicate var 'a'/)
    end
  end

  describe "artifacts" do
    def parse_block(body)
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block b
          interface docker img1
        #{body.lines.map { |l| "  #{l}" }.join}
         exit
        exit
      SRC
      doc.processes.first.blocks.first
    end

    it "parses produces with a relative path" do
      block = parse_block("produces model.pkl\nproduces metrics.json\n")
      expect(block.produces).to eq(%w[model.pkl metrics.json])
    end

    it "parses produces with subdirectories" do
      block = parse_block("produces subdir/file.json\n")
      expect(block.produces).to eq(["subdir/file.json"])
    end

    it "rejects duplicate produces" do
      expect { parse_block("produces a.json\nproduces a.json\n") }
        .to raise_error(Prouterd::Config::ParseError, /duplicate produces 'a.json'/)
    end

    it "rejects absolute produces path" do
      expect { parse_block("produces /etc/passwd\n") }
        .to raise_error(Prouterd::Config::ParseError, /must be a relative path/)
    end

    it "rejects produces with .. traversal" do
      expect { parse_block("produces ../escape.txt\n") }
        .to raise_error(Prouterd::Config::ParseError, /must be a relative path/)
    end

    it "parses implicit `input from <block>.<relpath>` and derives local_name from basename" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block train
          interface docker img1
          produces model.pkl
          produces metrics.json
         exit
         block deploy
          interface docker img2
          input from train.model.pkl
          input from train.metrics.json
         exit
         route train deploy
        exit
      SRC
      deploy = doc.processes.first.blocks.last
      expect(deploy.artifact_inputs.length).to eq(2)
      expect(deploy.artifact_inputs.map(&:local_name)).to eq(%w[model metrics])
      expect(deploy.artifact_inputs.map(&:from_artifact)).to eq(%w[model.pkl metrics.json])
    end

    it "derives local_name from the basename of a subdirectory path" do
      doc = parse_with_ifaces(<<~SRC)
        router x
        exit
        process p
         block t
          interface docker img1
          produces sub/file.json
         exit
         block d
          interface docker img2
          input from t.sub/file.json
         exit
         route t d
        exit
      SRC
      ai = doc.processes.first.blocks.last.artifact_inputs.first
      expect(ai.local_name).to eq("file")
      expect(ai.from_artifact).to eq("sub/file.json")
    end

    it "rejects bare `input <ctx.path>` (context flow now via templating in call-fields)" do
      expect { parse_block("input event.body\n") }
        .to raise_error(Prouterd::Config::ParseError, /supports only `input from/)
    end

    it "rejects malformed artifact reference" do
      expect { parse_block("input from train_only_block\n") }
        .to raise_error(Prouterd::Config::ParseError, /from <block>.<relpath>/)
    end

    it "rejects an artifact whose basename is not a valid identifier" do
      expect { parse_block("input from train.weird-name.pkl\n") }
        .to raise_error(Prouterd::Config::ParseError, /cannot derive a local name/)
    end
  end

  describe "call-field `file <path>` form" do
    require "tempfile"
    require "tmpdir"

    let(:tmpdir) { Dir.mktmpdir("prc-file-form-") }
    after { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

    def parse_with_base_dir(src, base_dir)
      described_class.parse(Prouterd::Config::Lexer.tokenize(src), base_dir: base_dir)
    end

    let(:llm_iface_src) do
      <<~PRC
        interface llm chat
         provider anthropic
         model claude-haiku-4-5-20251001
        exit
      PRC
    end

    it "inlines an external file into a :command call-field" do
      File.write(File.join(tmpdir, "sys.md"), "You are concise.\n")
      File.write(File.join(tmpdir, "user.md"), "Summarize: {{event.body}}\n")

      doc = parse_with_base_dir(<<~SRC, tmpdir)
        #{llm_iface_src}
        process p
         block summarize
          interface llm chat
          system file "sys.md"
          prompt file "user.md"
         exit
        exit
      SRC

      block = doc.processes.first.blocks.first
      expect(block.type_fields["system"]).to eq("You are concise.\n")
      expect(block.type_fields["prompt"]).to eq("Summarize: {{event.body}}\n")
    end

    it "errors when the file is missing" do
      expect {
        parse_with_base_dir(<<~SRC, tmpdir)
          #{llm_iface_src}
          process p
           block summarize
            interface llm chat
            prompt file "nope.md"
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /cannot read prompt file 'nope\.md'.*not found/)
    end

    it "errors when no base_dir was provided" do
      File.write(File.join(tmpdir, "user.md"), "x")
      expect {
        described_class.parse(
          Prouterd::Config::Lexer.tokenize(<<~SRC)
            #{llm_iface_src}
            process p
             block summarize
              interface llm chat
              prompt file "user.md"
             exit
            exit
          SRC
        )
      }.to raise_error(Prouterd::Config::ParseError, /requires a base directory/)
    end

    it "rejects extra tokens after the path" do
      expect {
        parse_with_base_dir(<<~SRC, tmpdir)
          #{llm_iface_src}
          process p
           block summarize
            interface llm chat
            prompt file "user.md" extra
           exit
          exit
        SRC
      }.to raise_error(Prouterd::Config::ParseError, /syntax: prompt file <path>/)
    end
  end
end
