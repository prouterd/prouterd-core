require "spec_helper"

# Phase 37m: end-to-end integration of agentic-block runtime through
# the orchestrator. Mocks the LLM HTTP layer; tool dispatch goes
# through a real CallRunner against a stubbed docker iface.
RSpec.describe "agentic block runtime" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::CallRunner.new }
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
      interface http stub
       base-url "https://example.test"
      exit
      tool search
       description "Web search."
       args query
       implementation interface http stub call get
      exit
      process p
       block deep_dive
        interface llm m
        prompt "find ruby agentic"
        agentic on
        allowed-tools search
        tool-call-limit 4
       exit
      exit
    PRC
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  it "runs the LLM/tool loop end-to-end and persists the agentic output_json" do
    # Mock the LLM provider's HTTP responses: first a tool_use, then text.
    responses = [
      {
        body_json: {
          "stop_reason" => "tool_use",
          "usage" => { "input_tokens" => 30, "output_tokens" => 12 },
          "content" => [
            { "type" => "tool_use", "id" => "tu_1", "name" => "search",
              "input" => { "query" => "ruby agentic" } }
          ]
        }
      },
      {
        body_json: {
          "stop_reason" => "end_turn",
          "usage" => { "input_tokens" => 60, "output_tokens" => 18 },
          "content" => [{ "type" => "text", "text" => "Done." }]
        }
      }
    ]
    queue = responses.dup
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, **_rest|
      response = queue.shift or raise "no more LLM responses"
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: JSON.dump(response[:body_json]), body_json: response[:body_json]
      )
    end

    # The tool dispatch synthesizes a RunRequest against the http
    # iface; CallRunner dispatches to HttpCaller. HttpCaller will hit
    # HttpClient.request, which we want to differentiate from the LLM
    # call. Re-mock HttpClient.request to also handle the tool URL.
    allow(Prouterd::Iface::HttpClient).to receive(:request).and_wrap_original do |original, method:, uri:, **rest|
      if uri.host == "example.test"
        Prouterd::Iface::HttpClient::Response.new(
          status: 200,
          body_text: JSON.dump("ok" => true, "hits" => 3),
          body_json: { "ok" => true, "hits" => 3 }
        )
      else
        # LLM provider path — dequeue from the canned list.
        response = queue.shift or raise "no more LLM responses"
        Prouterd::Iface::HttpClient::Response.new(
          status: 200, body_text: JSON.dump(response[:body_json]), body_json: response[:body_json]
        )
      end
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    persisted = repo.get_run_by_uid(run.uid)
    expect(persisted.tokens_in).to eq(90)
    expect(persisted.tokens_out).to eq(30)

    step = repo.list_steps(run.id).find { |s| s.block_name == "deep_dive" }
    expect(step.status).to eq("success")
    out = JSON.parse(step.output_json)
    expect(out["text"]).to eq("Done.")
    expect(out["stop_reason"]).to eq("end_turn")
    expect(out["tool_calls"].length).to eq(1)
    expect(out["tool_calls"].first["name"]).to eq("search")
  end

  it "fails the block clearly when the interface uses a non-anthropic provider" do
    src = <<~PRC
      router demo
      exit
      interface llm m
       provider openai
       model gpt-4o-mini
      exit
      tool t
       args x
       implementation interface llm m call openai
      exit
      process p
       block b
        interface llm m
        prompt "hi"
        agentic on
        allowed-tools t
       exit
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))

    run = orchestrator.trigger(doc, "p", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("invalid_agentic")
    expect(run.error_summary).to include("anthropic")
  end
end
