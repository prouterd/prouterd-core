require "spec_helper"
require "json"
require "net/http"

RSpec.describe Prouterd::Iface::LlmCaller do
  before do
    @captured = nil
    @next_response = nil

    fake_adapter = Object.new
    fake_adapter.define_singleton_method(:request) do |req|
      headers = {}
      req.each_header { |k, v| headers[k] = v }
      Thread.current[:captured] = {
        method:  req.method,
        path:    req.path,
        body:    req.body && JSON.parse(req.body),
        headers: headers
      }
      Thread.current[:next_response]
    end

    allow(Net::HTTP).to receive(:start) do |_host, _port, **_opts, &block|
      block.call(fake_adapter)
    end
  end

  def stub_response(status:, body:)
    response = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
    response.instance_variable_set(:@body, JSON.dump(body))
    response.instance_variable_set(:@read, true)
    Thread.current[:next_response] = response
  end

  def captured
    Thread.current[:captured]
  end

  def build_request(provider:, model:, prompt:, system: nil, max_tokens: nil, temperature: nil,
                    secret_name: nil, env: {}, base_url: nil)
    type_fields = { "provider" => provider, "model" => model, "prompt" => prompt }
    type_fields["system"] = system if system
    type_fields["max-tokens"] = max_tokens if max_tokens
    type_fields["temperature"] = temperature if temperature
    type_fields["base-url"] = base_url if base_url
    if secret_name
      type_fields["auth"] = Prouterd::Config::AST::Auth.new(scheme: "bearer", secret_name: secret_name, line: 1)
    end

    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "llm", attempt: 1,
      env: env, input_json: {}, timeout_ms: nil,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  describe "anthropic" do
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
      result = described_class.new.run(build_request(
        provider: "anthropic", model: "claude-haiku-4-5-20251001",
        prompt: "ping", max_tokens: "100",
        secret_name: "K", env: { "K" => "anthropic-secret-key" }
      ))

      expect(result.exit_code).to eq(0)
      expect(result.output_json["text"]).to eq("Hello from Claude.")
      expect(result.output_json["usage"]).to eq("input_tokens" => 7, "output_tokens" => 5)
      expect(result.output_json["stop_reason"]).to eq("end_turn")
      expect(result.output_json).not_to have_key("raw")

      expect(captured[:headers]["x-api-key"]).to eq("anthropic-secret-key")
      expect(captured[:headers]["anthropic-version"]).to eq("2023-06-01")
      expect(captured[:body]["model"]).to eq("claude-haiku-4-5-20251001")
      expect(captured[:body]["max_tokens"]).to eq(100)
      expect(captured[:body]["messages"]).to eq([{ "role" => "user", "content" => "ping" }])
    end

    it "includes system prompt when provided" do
      stub_response(status: 200, body: anthropic_response)
      described_class.new.run(build_request(
        provider: "anthropic", model: "m", prompt: "ping",
        system: "be brief", secret_name: "K", env: { "K" => "k" }
      ))
      expect(captured[:body]["system"]).to eq("be brief")
    end

    it "passes temperature through when set" do
      stub_response(status: 200, body: anthropic_response)
      described_class.new.run(build_request(
        provider: "anthropic", model: "m", prompt: "p",
        temperature: "0.5", secret_name: "K", env: { "K" => "k" }
      ))
      expect(captured[:body]["temperature"]).to eq(0.5)
    end

    it "surfaces provider error messages on non-2xx" do
      stub_response(status: 401, body: { "error" => { "type" => "authentication_error", "message" => "invalid x-api-key" } })

      result = described_class.new.run(build_request(
        provider: "anthropic", model: "m", prompt: "ping",
        secret_name: "K", env: { "K" => "bad" }
      ))
      expect(result.exit_code).to eq(401)
      expect(result.error_type).to eq("llm_error")
      expect(result.error_message).to include("invalid x-api-key")
    end
  end

  describe "openai" do
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
      result = described_class.new.run(build_request(
        provider: "openai", model: "gpt-4o-mini", prompt: "ping",
        system: "be brief", secret_name: "O", env: { "O" => "openai-secret-key" }
      ))

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
      result = described_class.new.run(build_request(
        provider: "anthropic", model: "m", prompt: ""
      ))
      expect(result.error_type).to eq("invalid_call")
      expect(result.error_message).to include("prompt")
    end

    it "errors with invalid_provider on an unknown provider" do
      result = described_class.new.run(build_request(
        provider: "ghost", model: "m", prompt: "p"
      ))
      expect(result.error_type).to eq("invalid_provider")
    end

    it "supports a base-url override" do
      stub_response(status: 200, body: { "content" => [{ "type" => "text", "text" => "" }], "usage" => {} })
      described_class.new.run(build_request(
        provider: "anthropic", model: "m", prompt: "p",
        base_url: "https://proxy.example.com"
      ))
      expect(captured[:path]).to eq("/v1/messages")
    end
  end
end
