require "spec_helper"
require "json"
require "net/http"

RSpec.describe Prouterd::Iface::LlmCaller do
  # Capture the last request without going to the network. We patch
  # Net::HTTP.start to call the request closure with a fake adapter that
  # records what it was given and returns a configured fake response.
  before do
    @last_request = nil
    @next_status = 200
    @next_body   = nil

    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:request) do |req|
      headers = {}
      req.each_header { |k, v| headers[k] = v }
      $captured_request = {
        method: req.method,
        path:   req.path,
        body:   req.body && JSON.parse(req.body),
        headers: headers
      }
      $next_response
    end

    allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
      block.call(fake_adapter)
    end
  end

  def stub_response(status:, body:)
    response = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, JSON.dump(body))
    response.instance_variable_set(:@read, true)
    $next_response = response
  end

  def captured
    $captured_request
  end

  def fake_iface(provider:, model:, secret_name: nil, base_url: nil)
    type_fields = { "provider" => provider, "model" => model }
    type_fields["base-url"] = base_url if base_url
    if secret_name
      type_fields["auth"] = Prouterd::Config::AST::Auth.new(scheme: "bearer", secret_name: secret_name, line: 1)
    end
    Struct.new(:name, :type, :type_fields).new("test", provider, type_fields)
  end

  describe "anthropic" do
    let(:iface) { fake_iface(provider: "anthropic", model: "claude-haiku-4-5-20251001", secret_name: "K") }

    let(:anthropic_response) do
      {
        "id" => "msg_1", "type" => "message", "role" => "assistant",
        "model" => "claude-haiku-4-5-20251001",
        "content" => [{ "type" => "text", "text" => "Hello from Claude." }],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 7, "output_tokens" => 5 }
      }
    end

    it "POSTs to /v1/messages with x-api-key + anthropic-version" do
      stub_response(status: 200, body: anthropic_response)

      result = described_class.new.call(
        iface: iface,
        call_fields: { "prompt" => "ping", "max-tokens" => "100" },
        secrets: { "K" => "anthropic-secret-key" }
      )

      expect(result.exit_code).to eq(0)
      expect(result.output_json["text"]).to eq("Hello from Claude.")
      expect(result.output_json["usage"]).to eq("input_tokens" => 7, "output_tokens" => 5)
      expect(result.output_json["stop_reason"]).to eq("end_turn")

      expect(captured[:method]).to eq("POST")
      expect(captured[:path]).to eq("/v1/messages")
      expect(captured[:headers]["x-api-key"]).to eq("anthropic-secret-key")
      expect(captured[:headers]["anthropic-version"]).to eq("2023-06-01")
      expect(captured[:body]["model"]).to eq("claude-haiku-4-5-20251001")
      expect(captured[:body]["max_tokens"]).to eq(100)
      expect(captured[:body]["messages"]).to eq([{ "role" => "user", "content" => "ping" }])
    end

    it "includes system prompt when provided" do
      stub_response(status: 200, body: anthropic_response)
      described_class.new.call(
        iface: iface,
        call_fields: { "prompt" => "ping", "system" => "be brief" },
        secrets: { "K" => "k" }
      )
      expect(captured[:body]["system"]).to eq("be brief")
    end

    it "passes temperature through when set" do
      stub_response(status: 200, body: anthropic_response)
      described_class.new.call(
        iface: iface,
        call_fields: { "prompt" => "ping", "temperature" => "0.5" },
        secrets: { "K" => "k" }
      )
      expect(captured[:body]["temperature"]).to eq(0.5)
    end

    it "surfaces provider error messages on non-2xx" do
      stub_response(status: 401, body: { "error" => { "type" => "authentication_error", "message" => "invalid x-api-key" } })

      result = described_class.new.call(
        iface: iface,
        call_fields: { "prompt" => "ping" },
        secrets: { "K" => "bad" }
      )
      expect(result.exit_code).to eq(401)
      expect(result.error_type).to eq("llm_error")
      expect(result.error_message).to include("invalid x-api-key")
    end
  end

  describe "openai" do
    let(:iface) { fake_iface(provider: "openai", model: "gpt-4o-mini", secret_name: "O") }

    let(:openai_response) do
      {
        "id" => "chatcmpl-1", "model" => "gpt-4o-mini",
        "choices" => [{
          "index" => 0,
          "message" => { "role" => "assistant", "content" => "Hello from GPT." },
          "finish_reason" => "stop"
        }],
        "usage" => { "prompt_tokens" => 7, "completion_tokens" => 4 }
      }
    end

    it "POSTs to /v1/chat/completions with bearer Authorization" do
      stub_response(status: 200, body: openai_response)

      result = described_class.new.call(
        iface: iface,
        call_fields: { "prompt" => "ping", "system" => "be brief" },
        secrets: { "O" => "openai-secret-key" }
      )

      expect(result.exit_code).to eq(0)
      expect(result.output_json["text"]).to eq("Hello from GPT.")
      expect(result.output_json["usage"]).to eq("input_tokens" => 7, "output_tokens" => 4)
      expect(result.output_json["stop_reason"]).to eq("stop")

      expect(captured[:path]).to eq("/v1/chat/completions")
      expect(captured[:headers]["authorization"]).to eq("Bearer openai-secret-key")
      expect(captured[:body]["model"]).to eq("gpt-4o-mini")
      expect(captured[:body]["messages"]).to eq([
        { "role" => "system", "content" => "be brief" },
        { "role" => "user",   "content" => "ping" }
      ])
    end
  end

  describe "validation" do
    it "errors with invalid_call when prompt is missing" do
      iface = fake_iface(provider: "anthropic", model: "m")
      result = described_class.new.call(iface: iface, call_fields: { "prompt" => "" })
      expect(result.error_type).to eq("invalid_call")
      expect(result.error_message).to include("prompt")
    end

    it "errors with invalid_provider on an unknown provider" do
      iface = fake_iface(provider: "ghost", model: "m")
      result = described_class.new.call(iface: iface, call_fields: { "prompt" => "p" })
      expect(result.error_type).to eq("invalid_provider")
    end

    it "supports a base-url override" do
      stub_response(status: 200, body: { "content" => [{ "type" => "text", "text" => "" }], "usage" => {} })
      iface = fake_iface(provider: "anthropic", model: "m", base_url: "https://proxy.example.com")
      described_class.new.call(iface: iface, call_fields: { "prompt" => "p" })
      # Path remains /v1/messages — base-url just changes the host.
      expect(captured[:path]).to eq("/v1/messages")
    end
  end
end
