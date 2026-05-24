require "spec_helper"
require "tempfile"
require "tmpdir"

RSpec.describe Prouterd::Iface::LlmAgentic do
  def fake_tool(name, args, description: "")
    tool = Prouterd::Config::AST::Tool.new(name: name, line: 1)
    tool.description = description
    tool.args.replace(args)
    tool
  end

  def http_response(status:, body_json: nil, body_text: nil)
    Prouterd::Iface::HttpClient::Response.new(
      status: status,
      body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
      body_json: body_json
    )
  end

  let(:tool) { fake_tool("search", %w[query]) }

  describe "anthropic HTTP path" do
    it "ends immediately when the first turn has no tool_use blocks" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        http_response(status: 200, body_json: {
          "stop_reason" => "end_turn",
          "usage" => { "input_tokens" => 2, "output_tokens" => 1 },
          "content" => [{ "type" => "text", "text" => "no tools" }]
        })
      )
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "x", system_msg: "",
        max_tokens: 16, max_turns: 5,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } }
      )
      expect(outcome[:ok]).to be true
      expect(outcome[:output_json]["text"]).to eq("no tools")
    end

    it "rescues a tool dispatcher exception, returns is_error tool_result, and finishes" do
      seen_messages = []
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        payload = JSON.parse(body)
        seen_messages << payload["messages"]
        if payload["messages"].length == 1
          http_response(status: 200, body_json: {
            "stop_reason" => "tool_use",
            "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
            "content" => [{ "type" => "tool_use", "id" => "tu", "name" => "search",
                            "input" => { "query" => "x" } }]
          })
        else
          http_response(status: 200, body_json: {
            "stop_reason" => "end_turn",
            "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
            "content" => [{ "type" => "text", "text" => "ok" }]
          })
        end
      end
      dispatcher = ->(name:, input:) { raise "tool exploded" }
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 3,
        tools: [tool], dispatcher: dispatcher
      )
      expect(outcome[:ok]).to be true
      user_turn = seen_messages.last.find { |m| m["role"] == "user" && m["content"].is_a?(Array) }
      tr = user_turn["content"].first
      expect(tr["is_error"]).to be true
      expect(tr["content"]).to include("tool exploded")
    end

    it "treats non-Hash dispatcher returns as a tool_dispatch error" do
      seen_messages = []
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        payload = JSON.parse(body)
        seen_messages << payload["messages"]
        if payload["messages"].length == 1
          http_response(status: 200, body_json: {
            "stop_reason" => "tool_use",
            "usage" => { "input_tokens" => 0, "output_tokens" => 0 },
            "content" => [{ "type" => "tool_use", "id" => "tu", "name" => "search",
                            "input" => { "query" => "q" } }]
          })
        else
          http_response(status: 200, body_json: {
            "stop_reason" => "end_turn",
            "usage" => { "input_tokens" => 0, "output_tokens" => 0 },
            "content" => [{ "type" => "text", "text" => "done" }]
          })
        end
      end
      dispatcher = ->(name:, input:) { "not a hash" }
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 3,
        tools: [tool], dispatcher: dispatcher
      )
      expect(outcome[:ok]).to be true
      user_turn = seen_messages.last.find { |m| m["role"] == "user" && m["content"].is_a?(Array) }
      tr = user_turn["content"].first
      expect(tr["is_error"]).to be true
      expect(tr["content"]).to include("tool_dispatch")
    end

    it "maps HttpClient::TimeoutError to error_type=timeout in the agentic loop" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::TimeoutError.new("read timeout"))
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "x", system_msg: "",
        max_tokens: 64, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } }
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("timeout")
    end

    it "maps HttpClient::RequestError to error_type=llm_error" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::RequestError.new("dns nope"))
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "x", system_msg: "",
        max_tokens: 64, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } }
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("llm_error")
    end

    it "falls back to body_text first line when non-2xx has no parseable JSON error" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        http_response(status: 500, body_text: "Internal Error\nmore details", body_json: nil)
      )
      outcome = described_class.run(
        model: "m", base_url: "https://api.anthropic.com", api_key: "k",
        prompt: "x", system_msg: "",
        max_tokens: 64, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } }
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_message]).to include("HTTP 500")
    end

    it "coerces max_turns nil / negative to DEFAULT_MAX_TURNS" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        http_response(status: 200, body_json: {
          "stop_reason" => "end_turn",
          "usage" => {}, "content" => [{ "type" => "text", "text" => "ok" }]
        })
      )
      [nil, -1].each do |bad|
        outcome = described_class.run(
          model: "m", base_url: "https://api.anthropic.com", api_key: "k",
          prompt: "x", system_msg: "",
          max_tokens: 16, max_turns: bad,
          tools: [tool], dispatcher: ->(*) { { output_json: {} } }
        )
        expect(outcome[:ok]).to be true
      end
    end

    it "includes the system field on the request body when system_msg is non-empty" do
      captured = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured = JSON.parse(body)
        http_response(status: 200, body_json: {
          "stop_reason" => "end_turn", "usage" => {},
          "content" => [{ "type" => "text", "text" => "ok" }]
        })
      end
      described_class.run(
        model: "m", base_url: "https://api.anthropic.com/", api_key: "k",
        prompt: "x", system_msg: "be brief",
        max_tokens: 16, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } }
      )
      expect(captured["system"]).to eq("be brief")
    end
  end

  describe ".schema_for" do
    it "honours an MCP-style input_schema verbatim" do
      mcp_tool = Object.new
      mcp_tool.define_singleton_method(:input_schema) { { "type" => "object", "properties" => { "x" => {} } } }
      mcp_tool.define_singleton_method(:args) { [] }
      expect(described_class.schema_for(mcp_tool)).to include("type" => "object")
    end

    it "synthesises a string-properties schema from an AST::Tool's args" do
      t = fake_tool("t", %w[a b])
      schema = described_class.schema_for(t)
      expect(schema["properties"]["a"]).to eq("type" => "string", "description" => "")
      expect(schema["required"]).to eq(%w[a b])
    end
  end

  describe ".tool_facing_name" do
    it "uses full_name when the tool responds to it" do
      t = Object.new
      t.define_singleton_method(:full_name) { "iface.tool" }
      t.define_singleton_method(:name) { "tool" }
      expect(described_class.tool_facing_name(t)).to eq("iface.tool")
    end

    it "falls back to name when no full_name available" do
      t = fake_tool("bare", [])
      expect(described_class.tool_facing_name(t)).to eq("bare")
    end
  end

  describe "subprocess agentic loop" do
    it "returns invalid_cwd when cwd is provided but does not exist" do
      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: "/usr/bin/true", home: nil, sandbox: nil,
        cwd: "/no/such/path-for-agentic",
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } },
        timeout_ms: 1_000
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("invalid_cwd")
    end

    it "coerces a negative max_turns to DEFAULT_MAX_TURNS in the subprocess path" do
      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: "/no/such/codex-binary-xyz2",
        home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: -3,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } },
        timeout_ms: 1_000
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("missing_dependency")
    end

    it "returns missing_dependency when the binary does not exist" do
      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: "/no/such/codex-binary-xyz",
        home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } },
        timeout_ms: 1_000
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("missing_dependency")
    end

    it "times out when the subprocess never produces a turn_completed event" do
      # Fake binary that holds stdout open but never writes a JSONL
      # event. The watchdog kills it on the agentic loop's deadline so
      # each_line returns and the outcome is `timeout`.
      f = Tempfile.create(["fake-agentic-hang-", ".sh"])
      f.write("#!/bin/sh\nsleep 10\n")
      f.close
      File.chmod(0o755, f.path)

      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: f.path, home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 1,
        tools: [tool], dispatcher: ->(*) { { output_json: {} } },
        timeout_ms: 200
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("timeout")
      File.unlink(f.path)
    end

    it "parses Hash arguments (not string) for codex function_call and dispatches" do
      f = Tempfile.create(["fake-agentic-hash-", ".sh"])
      f.write(<<~'BASH')
        #!/bin/sh
        read -r _first
        printf '%s\n' '{"type":"item.completed","item":{"type":"function_call","id":"call_1","name":"search","arguments":{"query":"q"}}}'
        printf '%s\n' '{"type":"turn.completed"}'
        read -r _out
        printf '%s\n' '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"done"}]}}'
        printf '%s\n' '{"type":"turn.completed","stop_reason":"end_turn"}'
      BASH
      f.close
      File.chmod(0o755, f.path)

      called = []
      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: f.path, home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 5,
        tools: [tool],
        dispatcher: ->(name:, input:) { called << [name, input]; { output_json: { "ok" => 1 } } },
        timeout_ms: 5_000
      )
      expect(outcome[:ok]).to be true
      expect(called.first).to eq(["search", { "query" => "q" }])
      File.unlink(f.path)
    end

    it "falls back to {} for malformed string arguments JSON" do
      f = Tempfile.create(["fake-agentic-malformed-", ".sh"])
      f.write(<<~'BASH')
        #!/bin/sh
        read -r _first
        printf '%s\n' '{"type":"item.completed","item":{"type":"function_call","id":"call_x","name":"search","arguments":"not json"}}'
        printf '%s\n' '{"type":"turn.completed"}'
        read -r _out
        printf '%s\n' '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"done"}]}}'
        printf '%s\n' '{"type":"turn.completed","stop_reason":"end_turn"}'
      BASH
      f.close
      File.chmod(0o755, f.path)

      called = []
      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: f.path, home: nil, sandbox: nil,
        prompt: "p", system_msg: "be brief",
        max_tokens: 16, max_turns: 5,
        tools: [tool],
        dispatcher: ->(name:, input:) { called << [name, input]; { output_json: { "ok" => 1 } } },
        timeout_ms: 5_000
      )
      expect(outcome[:ok]).to be true
      expect(called.first).to eq(["search", {}])
      File.unlink(f.path)
    end

    it "halts at max_turns when the subprocess keeps emitting tool calls" do
      # Each iteration: emit a function_call + turn.completed, then loop.
      f = Tempfile.create(["fake-agentic-loop-", ".sh"])
      f.write(<<~'BASH')
        #!/bin/sh
        # Read first message.
        read -r _first
        # Emit a function_call + turn.completed repeatedly. Each new
        # function_call_output message coming back triggers another turn.
        i=0
        while [ $i -lt 50 ]; do
          printf '%s\n' '{"type":"item.completed","item":{"type":"function_call","id":"call_'"$i"'","name":"search","arguments":"{}"}}'
          printf '%s\n' '{"type":"turn.completed"}'
          read -r _out || break
          i=$((i + 1))
        done
      BASH
      f.close
      File.chmod(0o755, f.path)

      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: f.path, home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 2,
        tools: [tool],
        dispatcher: ->(name:, input:) { { error_type: "boom", error_message: "go bad" } },
        timeout_ms: 10_000
      )
      expect(outcome[:ok]).to be true
      expect(outcome[:output_json]["stop_reason"]).to eq("max_turns")
    end

    it "surfaces an llm_error on non-zero subprocess exit with no stop_reason" do
      f = Tempfile.create(["fake-agentic-exit-", ".sh"])
      f.write(<<~'BASH')
        #!/bin/sh
        printf '%s\n' 'garbage line'
        exit 3
      BASH
      f.close
      File.chmod(0o755, f.path)

      outcome = described_class.run(
        provider: "codex_cli", model: "m",
        binary: f.path, home: nil, sandbox: nil,
        prompt: "p", system_msg: "",
        max_tokens: 16, max_turns: 1,
        tools: [tool],
        dispatcher: ->(*) { { output_json: {} } },
        timeout_ms: 5_000
      )
      expect(outcome[:ok]).to be false
      expect(outcome[:error_type]).to eq("llm_error")
      File.unlink(f.path)
    end
  end

  describe ".turn_completed?" do
    it "matches all the recognised shapes" do
      %w[turn.completed message_stop turn_complete].each do |t|
        expect(described_class.turn_completed?("type" => t)).to be true
      end
    end

    it "is false for any other event type" do
      expect(described_class.turn_completed?("type" => "thinking")).to be false
      expect(described_class.turn_completed?({})).to be false
    end
  end

  describe ".extract_event_text" do
    it "extracts delta.text" do
      expect(described_class.extract_event_text("delta" => { "text" => "x" })).to eq("x")
    end

    it "extracts message-content joined text parts" do
      ev = { "item" => { "type" => "message",
                          "content" => [{ "text" => "a" }, { "text" => "b" }] } }
      expect(described_class.extract_event_text(ev)).to eq("ab")
    end

    it "returns nil for an event with empty message content" do
      ev = { "item" => { "type" => "message", "content" => [] } }
      expect(described_class.extract_event_text(ev)).to be_nil
    end

    it "returns nil when nothing matches" do
      expect(described_class.extract_event_text({ "type" => "?" })).to be_nil
    end

    it "skips non-Hash parts inside message.content (covers parts.filter_map else)" do
      ev = { "item" => { "type" => "message",
                          "content" => ["not-a-hash", { "text" => "x" }] } }
      expect(described_class.extract_event_text(ev)).to eq("x")
    end
  end

  describe ".extract_event_function_call" do
    it "returns the function-call descriptor when item.type is function_call" do
      ev = { "item" => { "type" => "function_call", "id" => "i", "name" => "n", "arguments" => "{}" } }
      fc = described_class.extract_event_function_call(ev)
      expect(fc).to eq("id" => "i", "name" => "n", "arguments" => "{}")
    end

    it "falls back to call_id when id is absent" do
      ev = { "item" => { "type" => "function_call", "call_id" => "ci", "name" => "n", "arguments" => "{}" } }
      fc = described_class.extract_event_function_call(ev)
      expect(fc["id"]).to eq("ci")
    end

    it "returns nil for non-function_call items" do
      expect(described_class.extract_event_function_call("item" => { "type" => "message" })).to be_nil
      expect(described_class.extract_event_function_call({})).to be_nil
    end
  end

  describe ".failure" do
    it "builds the canonical failure shape" do
      f = described_class.failure(
        error_type: "x", message: "msg",
        usage_in: 1, usage_out: 2, tool_calls: [], turns: 0
      )
      expect(f).to include(ok: false, error_type: "x", error_message: "msg",
                            exit_code: nil, stdout: "", stderr: "msg")
      expect(f[:output_json]["usage"]).to eq("input_tokens" => 1, "output_tokens" => 2)
    end
  end

  describe ".invoke_tool" do
    it "wraps a non-hash return value as a tool_dispatch error" do
      out = described_class.invoke_tool(->(name:, input:) { "raw string" }, "n", {})
      expect(out).to include(error_type: "tool_dispatch")
    end

    it "wraps a thrown exception as a tool_dispatch error" do
      out = described_class.invoke_tool(->(name:, input:) { raise "boom" }, "n", {})
      expect(out[:error_type]).to eq("tool_dispatch")
      expect(out[:error_message]).to include("boom")
    end

    it "returns a hash unchanged when the dispatcher returns one" do
      out = described_class.invoke_tool(->(name:, input:) { { output_json: { "k" => 1 } } }, "n", {})
      expect(out).to eq(output_json: { "k" => 1 })
    end
  end
end
