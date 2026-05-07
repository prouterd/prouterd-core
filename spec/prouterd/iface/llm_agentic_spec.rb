require "spec_helper"

# Phase 37m: agentic multi-turn tool-use loop driver.
RSpec.describe Prouterd::Iface::LlmAgentic do
  # Build a tiny fake AST::Tool with the args we want exposed.
  def fake_tool(name, args, description: "")
    tool = Prouterd::Config::AST::Tool.new(name: name, line: 1)
    tool.description = description
    tool.args.replace(args)
    tool
  end

  # Stub HttpClient.request to return canned responses in order.
  def with_http_responses(responses)
    queue = responses.dup
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_kwargs|
      raise "no more canned responses" if queue.empty?

      response = queue.shift
      Prouterd::Iface::HttpClient::Response.new(
        status:    response[:status] || 200,
        body_text: response[:body_text] || JSON.dump(response[:body_json]),
        body_json: response[:body_json]
      )
    end
  end

  let(:tool) { fake_tool("search", %w[query], description: "Web search") }

  it "dispatches a tool_use turn, then returns text on the next turn" do
    with_http_responses([
      {
        body_json: {
          "stop_reason" => "tool_use",
          "usage"       => { "input_tokens" => 50, "output_tokens" => 10 },
          "content"     => [
            { "type" => "tool_use", "id" => "tu_1", "name" => "search",
              "input" => { "query" => "ruby agentic" } }
          ]
        }
      },
      {
        body_json: {
          "stop_reason" => "end_turn",
          "usage"       => { "input_tokens" => 80, "output_tokens" => 25 },
          "content"     => [
            { "type" => "text", "text" => "Found 3 results." }
          ]
        }
      }
    ])

    dispatched = []
    dispatcher = lambda do |name:, input:|
      dispatched << [name, input]
      { output_json: { "results" => ["a", "b", "c"] } }
    end

    outcome = described_class.run(
      model: "claude-haiku-4-5-20251001",
      base_url: "https://api.anthropic.com",
      api_key: "test-key",
      prompt: "find ruby agentic libs",
      system_msg: "be concise",
      max_tokens: 256,
      max_turns: 5,
      tools: [tool],
      dispatcher: dispatcher
    )

    expect(outcome[:ok]).to be true
    output = outcome[:output_json]
    expect(output["text"]).to eq("Found 3 results.")
    expect(output["stop_reason"]).to eq("end_turn")
    expect(output["usage"]).to eq("input_tokens" => 130, "output_tokens" => 35)
    expect(output["tool_calls"].length).to eq(1)
    expect(output["tool_calls"].first["name"]).to eq("search")
    expect(output["tool_calls"].first["input"]).to eq("query" => "ruby agentic")
    expect(output["tool_calls"].first["output"]).to eq("results" => ["a", "b", "c"])
    expect(dispatched).to eq([["search", { "query" => "ruby agentic" }]])
  end

  it "stops at max-turns and reports stop_reason=max_turns" do
    # Server keeps emitting tool_use; loop must bail.
    canned_tool_use = {
      body_json: {
        "stop_reason" => "tool_use",
        "usage"       => { "input_tokens" => 1, "output_tokens" => 1 },
        "content"     => [
          { "type" => "tool_use", "id" => "tu_x", "name" => "search",
            "input" => { "query" => "x" } }
        ]
      }
    }
    with_http_responses(Array.new(10) { canned_tool_use })

    dispatcher = ->(name:, input:) { { output_json: { "ok" => 1 } } }

    outcome = described_class.run(
      model: "m", base_url: "https://api.anthropic.com", api_key: "k",
      prompt: "x", system_msg: "",
      max_tokens: 64, max_turns: 2,
      tools: [tool], dispatcher: dispatcher
    )

    expect(outcome[:ok]).to be true
    expect(outcome[:output_json]["stop_reason"]).to eq("max_turns")
    expect(outcome[:output_json]["turns"]).to eq(3)
  end

  it "carries a tool dispatcher's error back as a tool_result with is_error" do
    seen_messages = []
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
      payload = JSON.parse(body)
      seen_messages << payload["messages"]
      response_json = if payload["messages"].length == 1
                        {
                          "stop_reason" => "tool_use",
                          "usage" => { "input_tokens" => 10, "output_tokens" => 5 },
                          "content" => [{ "type" => "tool_use", "id" => "tu", "name" => "search",
                                           "input" => { "query" => "q" } }]
                        }
                      else
                        {
                          "stop_reason" => "end_turn",
                          "usage" => { "input_tokens" => 20, "output_tokens" => 5 },
                          "content" => [{ "type" => "text", "text" => "ok, gave up" }]
                        }
                      end
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: JSON.dump(response_json), body_json: response_json
      )
    end

    dispatcher = ->(name:, input:) { { error_type: "tool_failed", error_message: "boom" } }

    outcome = described_class.run(
      model: "m", base_url: "https://api.anthropic.com", api_key: "k",
      prompt: "x", system_msg: "",
      max_tokens: 64, max_turns: 5,
      tools: [tool], dispatcher: dispatcher
    )

    expect(outcome[:ok]).to be true
    expect(outcome[:output_json]["text"]).to eq("ok, gave up")
    # Second request includes a user turn with tool_result+is_error.
    user_turn = seen_messages.last.find { |m| m["role"] == "user" && m["content"].is_a?(Array) }
    expect(user_turn).not_to be_nil
    tr = user_turn["content"].first
    expect(tr["type"]).to eq("tool_result")
    expect(tr["is_error"]).to be true
    expect(tr["content"]).to include("boom")
  end

  it "surfaces an HTTP non-2xx as llm_error without leaking the body" do
    error_body = { "error" => { "type" => "overloaded", "message" => "too many requests" } }
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      Prouterd::Iface::HttpClient::Response.new(
        status: 429, body_text: JSON.dump(error_body), body_json: error_body
      )
    end

    outcome = described_class.run(
      model: "m", base_url: "https://api.anthropic.com", api_key: "k",
      prompt: "x", system_msg: "",
      max_tokens: 64, max_turns: 1,
      tools: [tool], dispatcher: ->(*) { { output_json: {} } }
    )

    expect(outcome[:ok]).to be false
    expect(outcome[:error_type]).to eq("llm_error")
    expect(outcome[:error_message]).to include("HTTP 429")
    expect(outcome[:error_message]).to include("too many requests")
  end
end
