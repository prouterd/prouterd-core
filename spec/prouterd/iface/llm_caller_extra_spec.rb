require "spec_helper"
require "json"

# Coverage-extension specs for Prouterd::Iface::LlmCaller. Targets the
# branches missed by llm_caller_spec.rb: validation paths, error
# mapping, the parse_int / parse_float helpers, provider error message
# variants, and the resolve_token paths.
RSpec.describe Prouterd::Iface::LlmCaller do
  let(:caller_instance) { described_class.new }

  def build_request(type_fields, env: {})
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_x", process_name: "p", block_name: "b",
      execution_type: "llm", attempt: 1,
      env: env, input_json: {}, timeout_ms: nil,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  describe "missing-field validation" do
    it "errors with invalid_interface when provider is missing" do
      result = caller_instance.run(build_request({"provider" => "", "model" => "m", "prompt" => "p"}))
      expect(result.error_type).to eq("invalid_interface")
      expect(result.error_message).to include("provider")
    end

    it "errors with invalid_interface when model is missing" do
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "", "prompt" => "p"}))
      expect(result.error_type).to eq("invalid_interface")
      expect(result.error_message).to include("model")
    end

    it "errors with invalid_call when prompt is missing" do
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => ""}))
      expect(result.error_type).to eq("invalid_call")
      expect(result.error_message).to include("prompt")
    end
  end

  describe "request shape" do
    let(:anthropic_ok_response) do
      double_response(status: 200, body_json: {
        "id" => "msg_1", "model" => "m",
        "content" => [{ "type" => "text", "text" => "hi" }],
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
        "stop_reason" => "end_turn"
      })
    end

    def double_response(status:, body_text: nil, body_json: nil)
      Prouterd::Iface::HttpClient::Response.new(
        status: status,
        body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
        body_json: body_json
      )
    end

    it "treats an empty base-url override as 'use default'" do
      captured = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured = uri
        anthropic_ok_response
      end
      caller_instance.run(build_request({
        "provider" => "anthropic", "model" => "m", "prompt" => "p", "base-url" => ""
      }))
      expect(captured.host).to eq("api.anthropic.com")
    end

    it "returns invalid_provider when base-url is set but provider is unknown" do
      result = caller_instance.run(build_request({
        "provider" => "ghost", "model" => "m", "prompt" => "p",
        "base-url" => "https://x.example.com"
      }))
      expect(result.error_type).to eq("invalid_provider")
    end

    it "passes temperature through on OpenAI when set" do
      captured_body = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured_body = JSON.parse(body)
        Prouterd::Iface::HttpClient::Response.new(
          status: 200,
          body_text: JSON.dump({
            "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
            "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1 }
          }),
          body_json: {
            "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
            "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1 }
          }
        )
      end
      caller_instance.run(build_request({
        "provider" => "openai", "model" => "m", "prompt" => "p", "temperature" => "0.7"
      }))
      expect(captured_body["temperature"]).to eq(0.7)
    end

    it "skips non-text content blocks in anthropic shape_output" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        Prouterd::Iface::HttpClient::Response.new(
          status: 200,
          body_text: "",
          body_json: {
            "content" => [
              { "type" => "tool_use", "id" => "tu", "input" => {} },
              { "type" => "text", "text" => "hi" }
            ],
            "usage" => {}
          }
        )
      )
      result = caller_instance.run(build_request({
        "provider" => "anthropic", "model" => "m", "prompt" => "p"
      }))
      expect(result.output_json["text"]).to eq("hi")
    end

    it "honours base-url override" do
      captured = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured = uri
        anthropic_ok_response
      end
      caller_instance.run(build_request({        "provider" => "anthropic", "model" => "m", "prompt" => "p",
        "base-url" => "https://proxy.example.com/"
      }))
      expect(captured.host).to eq("proxy.example.com")
      expect(captured.path).to eq("/v1/messages")
    end

    it "returns invalid_provider when provider is unknown and no base-url is set" do
      result = caller_instance.run(build_request({        "provider" => "phantom", "model" => "m", "prompt" => "p"
      }))
      expect(result.error_type).to eq("invalid_provider")
    end

    it "builds an OpenAI body with messages array and no temperature/system when absent" do
      captured_body = nil
      captured_headers = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured_body = JSON.parse(body)
        captured_headers = headers
        double_response(status: 200, body_json: {
          "model" => "m",
          "choices" => [{ "message" => { "role" => "assistant", "content" => "ok" },
                          "finish_reason" => "stop" }],
          "usage" => { "prompt_tokens" => 2, "completion_tokens" => 3 }
        })
      end
      caller_instance.run(build_request({"provider" => "openai", "model" => "m", "prompt" => "p"}))
      expect(captured_body["messages"]).to eq([{ "role" => "user", "content" => "p" }])
      expect(captured_body).not_to have_key("temperature")
      expect(captured_headers).not_to have_key("authorization")
    end

    it "builds an Anthropic body without temperature/system when not provided" do
      captured_body = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured_body = JSON.parse(body)
        anthropic_ok_response
      end
      caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(captured_body).not_to have_key("system")
      expect(captured_body).not_to have_key("temperature")
    end
  end

  describe "shape_output edge cases" do
    def double_response(status:, body_text: nil, body_json: nil)
      Prouterd::Iface::HttpClient::Response.new(
        status: status,
        body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
        body_json: body_json
      )
    end

    it "anthropic with empty content array produces empty text" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 200, body_json: { "content" => [], "usage" => {} })
      )
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.output_json["text"]).to eq("")
      expect(result.output_json["usage"]).to eq("input_tokens" => nil, "output_tokens" => nil)
    end

    it "openai with no choices yields empty text and missing finish_reason" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 200, body_json: { "model" => "m", "choices" => [] })
      )
      result = caller_instance.run(build_request({"provider" => "openai", "model" => "m", "prompt" => "p"}))
      expect(result.output_json["text"]).to eq("")
      expect(result.output_json["stop_reason"]).to be_nil
    end

    it "openai handles choice with missing message hash" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 200, body_json: {
          "model" => "m", "choices" => [{ "finish_reason" => "stop" }]
        })
      )
      result = caller_instance.run(build_request({"provider" => "openai", "model" => "m", "prompt" => "p"}))
      expect(result.output_json["text"]).to eq("")
      expect(result.output_json["stop_reason"]).to eq("stop")
      expect(result.output_json["usage"]).to eq("input_tokens" => nil, "output_tokens" => nil)
    end
  end

  describe "HttpClient error mapping" do
    it "maps TimeoutError to error_type=timeout" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::TimeoutError.new("read timeout"))
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_type).to eq("timeout")
      expect(result.error_message).to include("read timeout")
    end

    it "maps RequestError to error_type=llm_error" do
      allow(Prouterd::Iface::HttpClient).to receive(:request)
        .and_raise(Prouterd::Iface::HttpClient::RequestError.new("dns nope"))
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_type).to eq("llm_error")
      expect(result.error_message).to include("dns nope")
    end

    it "rescues ArgumentError from inner build/parse to error_type=llm_error" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_raise(ArgumentError.new("argy"))
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_type).to eq("llm_error")
      expect(result.error_message).to include("argy")
    end
  end

  describe "non-2xx provider_error_message variants" do
    def double_response(status:, body_text: nil, body_json: nil)
      Prouterd::Iface::HttpClient::Response.new(
        status: status,
        body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
        body_json: body_json
      )
    end

    it "uses parsed['error'] when it's a Hash" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 500, body_json: { "error" => { "message" => "boom-hash" } })
      )
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_message).to include("boom-hash")
    end

    it "uses parsed['error'] when it's a String" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 502, body_json: { "error" => "boom-str" })
      )
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_message).to include("boom-str")
    end

    it "falls back to first_line of body_text when no parsed error key" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 503, body_text: "Service Unavailable\nmore details", body_json: nil)
      )
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_message).to include("Service Unavailable")
    end

    it "first_line handles an empty body" do
      allow(Prouterd::Iface::HttpClient).to receive(:request).and_return(
        double_response(status: 500, body_text: "", body_json: nil)
      )
      result = caller_instance.run(build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"}))
      expect(result.error_type).to eq("llm_error")
    end
  end

  describe "private helpers via .send" do
    let(:helper) { described_class.new }

    it "parse_int returns default for nil / empty / invalid; integer for valid" do
      expect(helper.send(:parse_int, nil, 7)).to eq(7)
      expect(helper.send(:parse_int, "", 7)).to eq(7)
      expect(helper.send(:parse_int, "abc", 7)).to eq(7)
      expect(helper.send(:parse_int, "42", 7)).to eq(42)
    end

    it "parse_float returns nil for nil/empty/invalid; float for valid" do
      expect(helper.send(:parse_float, nil)).to be_nil
      expect(helper.send(:parse_float, "")).to be_nil
      expect(helper.send(:parse_float, "abc")).to be_nil
      expect(helper.send(:parse_float, "1.5")).to eq(1.5)
    end

    it "provider_error_message returns nil for non-Hash inputs and missing error keys" do
      expect(helper.send(:provider_error_message, nil)).to be_nil
      expect(helper.send(:provider_error_message, "not a hash")).to be_nil
      expect(helper.send(:provider_error_message, { "foo" => 1 })).to be_nil
    end

    it "first_line returns empty string for empty input" do
      expect(helper.send(:first_line, "")).to eq("")
    end

    it "error helper builds the expected shape" do
      shape = helper.send(:error, "bad", "msg")
      expect(shape).to include(
        exit_code: nil, output_json: nil, stdout: "",
        error_type: "bad", error_message: "msg"
      )
    end

    it "resolve_token returns nil when no auth is set" do
      req = build_request({"provider" => "anthropic", "model" => "m", "prompt" => "p"})
      expect(helper.send(:resolve_token, req)).to be_nil
    end

    it "resolve_token reads the named secret from request.env when auth is set" do
      auth = Prouterd::Config::AST::Auth.new(scheme: "bearer", secret_name: "K", line: 1)
      req = build_request({ "provider" => "anthropic", "model" => "m", "prompt" => "p", "auth" => auth },
                          env: { "K" => "tok" })
      expect(helper.send(:resolve_token, req)).to eq("tok")
    end
  end

  describe "subprocess delegate path" do
    it "delegates codex_cli to LlmSubprocess.call (covers stream off branch)" do
      expect(Prouterd::Iface::LlmSubprocess).to receive(:call).and_return(
        exit_code: 0, output_json: {}, stdout: "", stderr: "",
        error_type: nil, error_message: nil
      )
      caller_instance.run(build_request({
        "provider" => "codex_cli", "model" => "m", "prompt" => "p",
        "binary" => "/usr/bin/true", "home" => "/tmp", "sandbox" => "read-only",
        "cwd" => "/tmp", "reasoning-effort" => "low",
        "env" => { "K" => "v" }, "env-forward" => [], "secret" => [],
        "stream" => "off"
      }))
    end

    it "passes stream_sink through when stream is on" do
      sink = ->(*) {}
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b", execution_type: "llm",
        attempt: 1, env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "provider" => "codex_cli", "model" => "m", "prompt" => "p",
                       "binary" => "/usr/bin/true",
                       "stream" => "on" },
        staged_inputs: {}, log_sink: sink
      )
      expect(Prouterd::Iface::LlmSubprocess).to receive(:call).with(
        hash_including(stream: true, stream_sink: sink)
      ).and_return(exit_code: 0, output_json: {}, stdout: "", stderr: "",
                    error_type: nil, error_message: nil)
      caller_instance.run(req)
    end
  end

  describe "openai with empty token" do
    def double_response(status:, body_text: nil, body_json: nil)
      Prouterd::Iface::HttpClient::Response.new(
        status: status,
        body_text: body_text || (body_json ? JSON.dump(body_json) : ""),
        body_json: body_json
      )
    end

    it "omits the Authorization header when the resolved token is empty" do
      captured_headers = nil
      allow(Prouterd::Iface::HttpClient).to receive(:request) do |method:, uri:, headers:, body:, timeout_ms:|
        captured_headers = headers
        double_response(status: 200, body_json: {
          "choices" => [{ "message" => { "content" => "x" }, "finish_reason" => "stop" }],
          "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1 }
        })
      end
      auth = Prouterd::Config::AST::Auth.new(scheme: "bearer", secret_name: "K", line: 1)
      caller_instance.run(build_request({
        "provider" => "openai", "model" => "m", "prompt" => "p", "auth" => auth
      }, env: { "K" => "" }))
      expect(captured_headers).not_to have_key("authorization")
    end
  end
end
