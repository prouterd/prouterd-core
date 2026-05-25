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

    it "auto-includes every mcp-advertised tool when block has mcp_refs but no allowed-tools" do
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
          mcp mid
         exit
        exit
      PRC
      mcp_pool = double
      allow(mcp_pool).to receive(:tool_snapshot).with(["mid"]).and_return(
        "mid" => [
          { "name" => "search",  "description" => "s", "inputSchema" => {} },
          { "name" => "fetch",   "description" => "f", "inputSchema" => {} }
        ]
      )
      block_executor = Prouterd::Runtime::BlockExecutor.new(
        db: db, runs: runs, runner: runner_stub,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default,
        logger: Prouterd::NullLogger.new, mcp_pool: mcp_pool,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      ar = described_class.new(runs: runs, runner: runner_stub, mcp_pool: mcp_pool, host: block_executor)
      captured_tools = nil
      allow(Prouterd::Iface::LlmAgentic).to receive(:run) do |**kwargs|
        captured_tools = kwargs[:tools]
        { ok: true, output_json: { "text" => "ok" }, exit_code: 0,
          stdout: "", stderr: "", error_type: nil, error_message: nil }
      end

      process = doc.processes.first
      block = process.blocks.first
      ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(captured_tools.length).to eq(2)
      expect(captured_tools.map(&:full_name)).to contain_exactly("mid.search", "mid.fetch")
    end

    it "passes non-String call_field values through untemplated and clears empty base-url" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface llm m
         provider anthropic
         base-url ""
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
         exit
        exit
      PRC
      # set a non-String value on the templated_call key so the
      # `raw.is_a?(String) ? render : raw` else branch fires
      doc.processes.first.blocks.first.type_fields["cwd"] = 42

      block_executor = Prouterd::Runtime::BlockExecutor.new(
        db: db, runs: runs, runner: runner_stub,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default,
        logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      ar = described_class.new(runs: runs, runner: runner_stub, mcp_pool: nil, host: block_executor)
      captured = nil
      allow(Prouterd::Iface::LlmAgentic).to receive(:run) do |**kwargs|
        captured = kwargs
        { ok: true, output_json: { "text" => "ok" }, exit_code: 0,
          stdout: "", stderr: "", error_type: nil, error_message: nil }
      end
      process = doc.processes.first
      block = process.blocks.first
      ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(captured[:base_url]).to eq("https://api.anthropic.com")
      expect(captured[:cwd]).to eq(42)
    end

    it "clamps max-tokens < 1 to the default 1024 and forwards failure outcomes" do
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
          max-tokens 0
         exit
        exit
      PRC
      # Block carries a non-String call_field (cwd unset → nil), which
      # exercises the `raw.is_a?(String) ? ... : raw` else branch.
      block_executor = Prouterd::Runtime::BlockExecutor.new(
        db: db, runs: runs, runner: runner_stub,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default,
        logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      ar = described_class.new(runs: runs, runner: runner_stub, mcp_pool: nil, host: block_executor)
      captured = nil
      allow(Prouterd::Iface::LlmAgentic).to receive(:run) do |**kwargs|
        captured = kwargs
        # outcome failure: ok=false, no output_json
        { ok: false, output_json: nil, exit_code: 1,
          stdout: "", stderr: "oops", error_type: "llm_error", error_message: "broke" }
      end
      process = doc.processes.first
      block = process.blocks.first
      res = ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(captured[:max_tokens]).to eq(1024)
      expect(res.error_type).to eq("llm_error")
    end

    it "resolves api_key from build_env when interface declares `auth bearer secret`" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        secret CLAUDE_KEY
         source env CLAUDE_KEY
        exit
        interface llm m
         provider anthropic
         auth bearer secret CLAUDE_KEY
        exit
        process p
         block b
          interface llm m
          prompt "hi"
          agentic on
         exit
        exit
      PRC
      ENV["CLAUDE_KEY"] = "ek-xyz"
      block_executor = Prouterd::Runtime::BlockExecutor.new(
        db: db, runs: runs, runner: runner_stub,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default,
        logger: Prouterd::NullLogger.new, mcp_pool: nil,
        retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      ar = described_class.new(runs: runs, runner: runner_stub, mcp_pool: nil, host: block_executor)
      captured_api_key = nil
      allow(Prouterd::Iface::LlmAgentic).to receive(:run) do |**kwargs|
        captured_api_key = kwargs[:api_key]
        { ok: true, output_json: { "text" => "ok" }, exit_code: 0,
          stdout: "", stderr: "", error_type: nil, error_message: nil }
      end
      process = doc.processes.first
      block = process.blocks.first
      ar.execute(run, process, block, context, doc, db_mutex, ctx_mutex, redactor, 1)
      expect(captured_api_key).to eq("ek-xyz")
    ensure
      ENV.delete("CLAUDE_KEY")
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

    it "omits the 'call' field when impl.call_name is empty (defensive against malformed AST)" do
      # Parser forbids `implementation interface ... ` without `call <name>`,
      # so this path is defensive against an in-memory mutation /
      # third-party AST builder. Construct the AST directly.
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface shell sh
        exit
        tool stripped
         description "x"
         implementation interface shell sh call boom
        exit
      PRC
      tool = doc.tools.first
      tool.implementation = tool.implementation.dup
      tool.implementation.call_name = "" # mutate to empty

      captured_fields = nil
      runner = Class.new do
        define_method(:run) do |req|
          captured_fields = req.type_fields
          Prouterd::Runner::ExecutionResult.new(
            exit_code: 0, stdout: "", stderr: "",
            output_json: { "ok" => true }, artifacts: [],
            error_type: nil, error_message: nil,
            duration_ms: 0, started_at: nil, finished_at: nil
          )
        end
      end.new
      ar = described_class.new(runs: runs, runner: runner, mcp_pool: nil, host: double)
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, double(name: "p"), block, doc, {})
      dispatcher.call(name: "stripped", input: {})
      expect(captured_fields).not_to have_key("call")
    end

    it "rejects a known tool whose implementation references a missing iface" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface shell sh
        exit
        tool with_missing_iface
         description "iface gets stripped after parse"
         implementation interface shell sh call boom
        exit
      PRC
      doc.interfaces.clear # strip the iface declaration after parse
      ar = described_class.new(runs: runs, runner: Prouterd::Runner::StubRunner.new, mcp_pool: nil, host: double)
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, double(name: "p"), block, doc, {})
      out = dispatcher.call(name: "with_missing_iface", input: {})
      expect(out[:error_type]).to eq("unknown_iface")
      expect(out[:error_message]).to include("shell sh")
    end

    it "surfaces tool_failed error_type when a declared tool's runner returns a failure" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface shell sh
        exit
        tool boom
         description "always fails"
         implementation interface shell sh call boom
        exit
      PRC
      # Stub a runner that returns a failed ExecutionResult.
      stub_runner = Class.new do
        def run(_req)
          Prouterd::Runner::ExecutionResult.new(
            exit_code: 7, stdout: "", stderr: "broke",
            output_json: nil, artifacts: [],
            error_type: "shell_error", error_message: "process crashed",
            duration_ms: 1, started_at: nil, finished_at: nil
          )
        end
      end.new
      ar = described_class.new(runs: runs, runner: stub_runner, mcp_pool: nil, host: double)
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, double(name: "p"), block, doc, {})
      out = dispatcher.call(name: "boom", input: {})
      expect(out[:error_type]).to eq("shell_error")
      expect(out[:error_message]).to eq("process crashed")
    end

    it "falls back to 'tool_failed' / generic message when runner failure carries no metadata" do
      doc = make_doc(<<~PRC)
        router demo
        exit
        interface shell sh
        exit
        tool silentboom
         description "fails with no metadata"
         implementation interface shell sh call boom
        exit
      PRC
      stub_runner = Class.new do
        def run(_req)
          Prouterd::Runner::ExecutionResult.new(
            exit_code: 1, stdout: "", stderr: "",
            output_json: nil, artifacts: [],
            error_type: nil, error_message: nil,
            duration_ms: 1, started_at: nil, finished_at: nil
          )
        end
      end.new
      ar = described_class.new(runs: runs, runner: stub_runner, mcp_pool: nil, host: double)
      block = double(name: "b", timeout_ms: nil)
      dispatcher = ar.send(:build_tool_dispatcher, run, double(name: "p"), block, doc, {})
      out = dispatcher.call(name: "silentboom", input: {})
      expect(out[:error_type]).to eq("tool_failed")
      expect(out[:error_message]).to include("silentboom")
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
