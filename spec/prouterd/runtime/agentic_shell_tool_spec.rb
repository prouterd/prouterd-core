require "spec_helper"

# Agentic dispatch routes LLM-supplied tool args through both
# `type_fields` (for HTTP-style call_fields) and `input_json` (for
# shell-backed tools whose only call_field is `exec` — args reach the
# script via /prouter/input.json).
RSpec.describe "agentic dispatch passes LLM args to shell-backed tools" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    src = <<~PRC
      router demo
      exit
      interface llm m
       provider anthropic
       model claude-haiku-4-5-20251001
      exit
      shell_tool jira
       description "Jira CLI"
       args op, key, jql
      exit
      process p
       block planner
        interface llm m
        prompt "use the tools"
        agentic on
        allowed-tools jira
        tool-call-limit 4
       exit
      exit
    PRC
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  it "writes the LLM-supplied tool args into the shell tool's input_json" do
    # First LLM turn: tool_use jira(op="search_issues", jql="project=X").
    # Second LLM turn: end_turn.
    responses = [
      {
        "stop_reason" => "tool_use",
        "usage" => { "input_tokens" => 5, "output_tokens" => 3 },
        "content" => [
          { "type" => "tool_use", "id" => "tu_1", "name" => "jira",
            "input" => { "op" => "search_issues", "jql" => "project = ATP" } }
        ]
      },
      {
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
        "content" => [{ "type" => "text", "text" => "ok" }]
      }
    ]
    queue = responses.dup
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      body = queue.shift or raise "no more LLM responses"
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: JSON.dump(body), body_json: body
      )
    end

    # Capture what the runner saw for the tool dispatch.
    runner.program("planner::tool::jira") do |req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "input_json_received" => req.input_json,
                       "type_fields_call" => req.type_fields["call"] },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    tool_request = runner.calls.find { |r| r.block_name == "planner::tool::jira" }
    expect(tool_request).not_to be_nil

    # The fix: input_json now carries the LLM args, so a shell script
    # reading /prouter/input.json sees `op` / `jql`.
    expect(tool_request.input_json).to eq(
      "op"  => "search_issues",
      "jql" => "project = ATP"
    )

    # type_fields still carries them too (HTTP-style backers depend on
    # this) — the fix is additive, not a swap.
    expect(tool_request.type_fields["op"]).to eq("search_issues")
    expect(tool_request.type_fields["jql"]).to eq("project = ATP")
    expect(tool_request.type_fields["call"]).to eq("exec")
  end
end
