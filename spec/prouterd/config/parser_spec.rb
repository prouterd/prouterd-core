require "spec_helper"

RSpec.describe Prouterd::Config::Parser do
  def parse(src)
    described_class.parse(Prouterd::Config::Lexer.tokenize(src))
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
      expect(iface.path).to eq("/leads")
      expect(iface.method).to eq("POST")
      expect(iface.auth.scheme).to eq("bearer")
      expect(iface.auth.secret_name).to eq("WEBHOOK_TOKEN")
      expect(iface.shutdown).to be(false)
    end

    it "rejects path field on manual interface" do
      expect do
        parse(<<~SRC)
          interface manual cli
           path /foo
          exit
        SRC
      end.to raise_error(Prouterd::Config::ParseError, /'path' is only valid in interface type 'webhook'/)
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
      expect(iface.schedule).to eq("0 9 * * *")
      expect(iface.timezone).to eq("Asia/Almaty")
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
      doc = parse(<<~SRC)
        process pipeline
         description "demo"
         queue default
         no shutdown

         block a
          image alpine:1
         exit
         block b
          image alpine:2
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
      doc = parse(<<~SRC)
        process pipeline
         block a
          image x
         exit
         block b
          image y
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

    it "parses block with secrets, retry policy, network and command" do
      doc = parse(<<~SRC)
        process p
         block enrich
          image registry.local/blocks/enrich:v3
          command "/bin/run --mode=safe"
          timeout 120s
          retry policy retry_standard
          secret CLEARBIT_API_KEY
          secret OTHER_KEY
          input lead.raw
          output lead.enriched
          network off
         exit
        exit
      SRC
      block = doc.processes.first.blocks.first
      expect(block.image).to eq("registry.local/blocks/enrich:v3")
      expect(block.command).to eq("/bin/run --mode=safe")
      expect(block.timeout_ms).to eq(120_000)
      expect(block.retry_policy_name).to eq("retry_standard")
      expect(block.secret_names).to eq(%w[CLEARBIT_API_KEY OTHER_KEY])
      expect(block.input).to eq("lead.raw")
      expect(block.output).to eq("lead.enriched")
      expect(block.network).to eq("off")
    end

    it "rejects duplicate secret in same block" do
      expect do
        parse(<<~SRC)
          process p
           block b
            image x
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
      m = doc.processes.first.routes.first.matches.first
      expect(m.operator).to eq("in")
      expect(m.values).to eq(%w[US EU KZ])
    end

    it "parses 'exists' operator with no values" do
      doc = parse(<<~SRC)
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
      m = doc.processes.first.routes.first.matches.first
      expect(m.operator).to eq("exists")
      expect(m.values).to be_empty
    end

    it "rejects unknown operator" do
      expect do
        parse(<<~SRC)
          process p
           block a
            image x
           exit
           block b
            image y
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
      expect(doc.interfaces.map(&:name)).to eq(["leads_in"])
      expect(doc.processes.length).to eq(1)
      pipeline = doc.processes.first
      expect(pipeline.blocks.map(&:name)).to eq(%w[extract enrich score notify_sales])
      expect(pipeline.routes.length).to eq(3)
      expect(doc.global_routes.length).to eq(1)
    end

    it "parses minimal.prc cleanly" do
      doc = parse(read_fixture("minimal.prc"))
      expect(doc.router.name).to eq("demo")
      expect(doc.processes.first.blocks.first.command).to eq("echo hello")
    end
  end
end
