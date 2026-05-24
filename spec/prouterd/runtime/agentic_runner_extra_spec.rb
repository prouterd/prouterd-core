require "spec_helper"

RSpec.describe Prouterd::Runtime::AgenticRunner do
  describe ".stringify_arg" do
    it "passes a String through unchanged" do
      expect(described_class.stringify_arg("hello")).to eq("hello")
    end

    it "returns '' for nil" do
      expect(described_class.stringify_arg(nil)).to eq("")
    end

    it "JSON-dumps Hash and Array values" do
      expect(described_class.stringify_arg({ "x" => 1 })).to eq('{"x":1}')
      expect(described_class.stringify_arg([1, 2])).to eq("[1,2]")
    end

    it "JSON-dumps numeric values" do
      expect(described_class.stringify_arg(42)).to eq("42")
      expect(described_class.stringify_arg(true)).to eq("true")
    end
  end

  describe "#invalid_agentic" do
    let(:runner) { described_class.new(runs: double, runner: double, mcp_pool: nil, host: double) }

    it "wraps a message in an invalid_agentic ExecutionResult" do
      block = double(name: "deep")
      res = runner.send(:invalid_agentic, block, "boom")
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("deep")
      expect(res.error_message).to include("boom")
      expect(res.exit_code).to be_nil
      expect(res.success?).to be(false)
    end
  end

  describe "#mcp_tool_descriptor" do
    let(:runs) { double }
    let(:runner) { double }
    let(:host) { double }

    it "returns nil when mcp_pool is missing" do
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: nil, host: host)
      expect(ar.send(:mcp_tool_descriptor, "iface", "tool")).to be_nil
    end

    it "returns nil when the tool isn't advertised" do
      mcp_pool = double
      allow(mcp_pool).to receive(:tool_snapshot).with(["iface"]).and_return({ "iface" => [] })
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: mcp_pool, host: host)
      expect(ar.send(:mcp_tool_descriptor, "iface", "nope")).to be_nil
    end

    it "returns a McpToolRef when the descriptor exists" do
      mcp_pool = double
      allow(mcp_pool).to receive(:tool_snapshot).with(["iface"]).and_return(
        { "iface" => [{ "name" => "search", "description" => "d", "inputSchema" => {} }] }
      )
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: mcp_pool, host: host)
      ref = ar.send(:mcp_tool_descriptor, "iface", "search")
      expect(ref).to be_a(Prouterd::Iface::McpToolRef)
      expect(ref.full_name).to eq("iface.search")
    end
  end

  describe "#tools_for_iface" do
    let(:runs) { double }
    let(:runner) { double }
    let(:host) { double }

    it "returns [] when mcp_pool is missing" do
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: nil, host: host)
      expect(ar.send(:tools_for_iface, "x")).to eq([])
    end

    it "returns [] when snapshot has no entry for the iface" do
      mcp_pool = double
      allow(mcp_pool).to receive(:tool_snapshot).with(["x"]).and_return({})
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: mcp_pool, host: host)
      expect(ar.send(:tools_for_iface, "x")).to eq([])
    end
  end

  describe "#execute invalid-shape guards" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:runner_stub) { Prouterd::Runner::StubRunner.new }
    let(:host) { double }
    let(:ar) { described_class.new(runs: runs, runner: runner_stub, mcp_pool: nil, host: host) }
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:db_mutex) { Monitor.new }
    let(:ctx_mutex) { Monitor.new }
    let(:context) { Prouterd::Runtime::Context.new({}) }
    let(:redactor) { Prouterd::Runtime::Redactor.new([]) }

    def make_doc(prc)
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
    end

    it "returns invalid_agentic when block doesn't reference an llm iface" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface docker x
         image foo
        exit
        process p
         block b
          interface docker x
          agentic on
         exit
        exit
      PRC
      process = doc.processes.first
      block = process.blocks.first
      block.agentic = true
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("agentic block must reference")
    end

    it "rejects provider claude_cli with a specific hint" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface llm m
         provider claude_cli
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
         exit
        exit
      PRC
      process = doc.processes.first
      block = process.blocks.first
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("claude_cli")
    end

    it "rejects unsupported providers" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface llm m
         provider openai
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
         exit
        exit
      PRC
      process = doc.processes.first
      block = process.blocks.first
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("anthropic/codex_cli")
    end

    it "rejects an allowed-tools entry that references a missing tool" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface llm m
         provider anthropic
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
          allowed-tools missing-tool
         exit
        exit
      PRC
      process = doc.processes.first
      block = process.blocks.first
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("unknown tool 'missing-tool'")
    end

    it "rejects a namespaced allowed-tools entry whose iface doesn't advertise it" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface llm m
         provider anthropic
        exit
        interface mcp mid
         server bin "true"
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
          allowed-tools mid.search
         exit
        exit
      PRC
      process = doc.processes.first
      block = process.blocks.first
      # No mcp_pool wired — tools_for_iface returns [] → descriptor nil
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(res.error_type).to eq("invalid_agentic")
      expect(res.error_message).to include("mid.search")
    end
  end

  describe "#build_tool_dispatcher" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }

    def make_doc(prc)
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
    end

    it "rejects an unknown tool name" do
      doc = make_doc(<<~PRC)
        router demo
        exit
      PRC
      ar = described_class.new(runs: runs, runner: Prouterd::Runner::StubRunner.new, mcp_pool: nil, host: double)
      process = double(name: "p")
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, process, block, doc, {})
      result = dispatcher.call(name: "search", input: {})
      expect(result[:error_type]).to eq("unknown_tool")
    end

    it "rejects a namespaced name when mcp_pool is not wired" do
      doc = make_doc(<<~PRC)
        router demo
        exit
      PRC
      ar = described_class.new(runs: runs, runner: Prouterd::Runner::StubRunner.new, mcp_pool: nil, host: double)
      process = double(name: "p")
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, process, block, doc, {})
      result = dispatcher.call(name: "mid.search", input: {})
      expect(result[:error_type]).to eq("mcp_unavailable")
    end

    it "delegates a namespaced name to mcp_pool.call_tool" do
      doc = make_doc(<<~PRC)
        router demo
        exit
      PRC
      mcp_pool = double
      expect(mcp_pool).to receive(:call_tool).with("mid.search", { "q" => "x" }, timeout_ms: 60_000).and_return({ output_json: { "hit" => 1 } })
      ar = described_class.new(runs: runs, runner: Prouterd::Runner::StubRunner.new, mcp_pool: mcp_pool, host: double)
      process = double(name: "p")
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, process, block, doc, {})
      result = dispatcher.call(name: "mid.search", input: { "q" => "x" })
      expect(result[:output_json]).to eq("hit" => 1)
    end

    it "uses block.timeout_ms when set" do
      doc = make_doc(<<~PRC)
        router demo
        exit
      PRC
      mcp_pool = double
      expect(mcp_pool).to receive(:call_tool).with("mid.s", {}, timeout_ms: 4000).and_return({ output_json: {} })
      ar = described_class.new(runs: runs, runner: Prouterd::Runner::StubRunner.new, mcp_pool: mcp_pool, host: double)
      block = double(name: "b", timeout_ms: 4000)
      dispatcher = ar.send(:build_tool_dispatcher, run, double(name: "p"), block, doc, {})
      dispatcher.call(name: "mid.s", input: nil)
    end
  end
end
