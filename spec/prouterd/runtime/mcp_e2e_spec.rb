require "spec_helper"

# End-to-end MCP integration: real subprocess (the spec/fixtures
# fake server), real Pool, real Orchestrator agentic loop with the
# LLM HTTP layer mocked. Covers:
#   - Pool snapshot lands in run.mcp_tools_json at trigger time
#   - The model receives the namespaced tool with the server's
#     real input_schema attached
#   - tool_use → tool_result round-trip through the pool
RSpec.describe "agentic block calling an MCP tool end-to-end" do
  let(:fake_path) { File.expand_path("../../fixtures/fake_mcp_server.rb", __dir__) }
  let(:db)       { Prouterd::Storage::DB.open(":memory:") }
  let(:runner)   { Prouterd::Runner::CallRunner.new }
  let(:resolver) { Class.new { def resolve(_); ""; end }.new }
  let(:pool)     { Prouterd::Iface::Mcp::Pool.new(secret_resolver: resolver) }
  let(:orchestrator) do
    Prouterd::Runtime::Orchestrator.new(db: db, runner: runner, mcp_pool: pool)
  end
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close; pool.stop }

  let(:document) do
    src = <<~PRC
      router demo
      exit
      interface llm m
       provider anthropic
       model claude-haiku-4-5-20251001
      exit
      interface mcp fake
       server raw "ruby #{fake_path}"
      exit
      process p
       block deep_dive
        interface llm m
        prompt "echo something"
        agentic on
        mcp fake
        allowed-tools fake.echo
        tool-call-limit 4
       exit
      exit
    PRC
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  before { pool.start_or_reconcile(document) }

  it "snapshots mcp_tools_json on enqueue" do
    run = orchestrator.enqueue(document, "p", input_event: {})
    persisted = repo.get_run_by_uid(run.uid)
    parsed = JSON.parse(persisted.mcp_tools_json)
    expect(parsed.keys).to eq(["fake"])
    expect(parsed["fake"].first["name"]).to eq("echo")
  end

  it "runs the model → tool-call → tool-result loop with the MCP server" do
    responses = [
      {
        "stop_reason" => "tool_use",
        "usage" => { "input_tokens" => 10, "output_tokens" => 4 },
        "content" => [
          { "type" => "tool_use", "id" => "tu_1", "name" => "fake.echo",
            "input" => { "msg" => "hello" } }
        ]
      },
      {
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 20, "output_tokens" => 6 },
        "content" => [{ "type" => "text", "text" => "All done." }]
      }
    ]
    queue = responses.dup
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      body = queue.shift or raise "no more LLM responses"
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: JSON.dump(body), body_json: body
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    step = repo.list_steps(run.id).find { |s| s.block_name == "deep_dive" }
    out = JSON.parse(step.output_json)
    expect(out["text"]).to eq("All done.")
    expect(out["tool_calls"].length).to eq(1)
    expect(out["tool_calls"].first["name"]).to eq("fake.echo")
  end

  it "fails the block when allowed-tools names a tool the server doesn't advertise" do
    bad = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface llm m
       provider anthropic
       model x
      exit
      interface mcp fake
       server raw "ruby #{fake_path}"
      exit
      process p
       block deep_dive
        interface llm m
        prompt "hi"
        agentic on
        mcp fake
        allowed-tools fake.never_existed
        tool-call-limit 1
       exit
      exit
    PRC
    pool.start_or_reconcile(bad)
    run = orchestrator.trigger(bad, "p", input_event: {})
    expect(run.status).to eq("failed")
    # `invalid_agentic` short-circuits before a step row is written;
    # the failure surfaces on the run summary or the synthetic step
    # row written by execute_single_attempt depending on path.
    error = run.error_summary ||
            repo.list_steps(run.id).map(&:error_message).compact.join(" | ")
    expect(error).to include("not advertised by mcp interface 'fake'")
  end
end
