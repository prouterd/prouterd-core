# frozen_string_literal: true

require "uri"
require "json"
require_relative "http_client"
require_relative "caller_timing"
require_relative "llm_subprocess"

module Prouterd
  module Iface
    # Caller for `interface llm`. Invoked by `Runner::CallRunner` when a
    # block references an outbound llm interface.
    #
    # Reads from `request.type_fields`:
    #   * provider    — "anthropic" | "openai"
    #   * model       — model identifier (e.g. "claude-haiku-4-5-20251001")
    #   * auth        — AST::Auth; resolved API key looked up from request.env
    #   * base-url    — optional override (defaults to provider's public URL)
    #   * prompt      — required user prompt
    #   * system      — optional system prompt
    #   * max-tokens  — string, parsed as int (default "1024")
    #   * temperature — optional, parsed as float
    #
    # Output JSON shape (provider-agnostic):
    #   { "text" => "...", "model" => "...",
    #     "usage" => { "input_tokens" => N, "output_tokens" => M },
    #     "stop_reason" => "..." }
    #
    # Net::HTTP / timeouts / JSON parse live in `Iface::HttpClient`. This
    # class only carries the LLM-specific shape work: per-provider request
    # body construction, header conventions (anthropic = x-api-key,
    # openai = Authorization: Bearer), response shape normalization.
    #
    # Note: the full provider response is intentionally NOT echoed back into
    # `output_json`. Some providers include the prompt or other context in
    # error responses, and that body would otherwise flow into the run
    # context for downstream blocks. Callers that need the raw response
    # should inspect step logs (which are redacted).
    class LlmCaller
      include CallerTiming

      DEFAULT_MAX_TOKENS = 1024

      DEFAULT_BASE_URL = {
        "anthropic" => "https://api.anthropic.com",
        "openai"    => "https://api.openai.com"
      }.freeze

      ANTHROPIC_VERSION = "2023-06-01".freeze

      private

      def perform_run(request)
        provider = request.field("provider").to_s
        model    = request.field("model").to_s
        return error("invalid_interface", "interface missing provider") if provider.empty?
        return error("invalid_interface", "interface missing model")    if model.empty?

        prompt = request.field("prompt").to_s
        return error("invalid_call", "block missing 'prompt'") if prompt.empty?

        system_msg  = request.field("system").to_s
        max_tokens  = parse_int(request.field("max-tokens"), DEFAULT_MAX_TOKENS)
        temperature = parse_float(request.field("temperature"))

        if %w[codex_cli claude_cli].include?(provider)
          extra_env, sandbox_env = build_subprocess_env(request)
          stream = request.field("stream").to_s == "on"
          stream_sink = stream ? request.log_sink : nil
          return LlmSubprocess.call(
            provider:         provider,
            model:            model,
            binary:           request.field("binary"),
            home:             request.field("home"),
            sandbox:          request.field("sandbox"),
            cwd:              request.field("cwd"),
            reasoning_effort: request.field("reasoning-effort"),
            extra_env:        extra_env,
            sandbox_env:      sandbox_env,
            stream:           stream,
            stream_sink:      stream_sink,
            prompt:           prompt,
            system_msg:       system_msg,
            timeout_ms:       request.timeout_ms
          )
        end

        auth_token = resolve_token(request)

        base_url = request.field("base-url")
        base_url = nil if base_url.respond_to?(:empty?) && base_url.empty?
        base_url ||= DEFAULT_BASE_URL[provider]
        return error("invalid_provider", "unknown provider '#{provider}'") unless base_url

        request_body, uri, headers = case provider
                                     when "anthropic"
                                       build_anthropic(base_url, model, prompt, system_msg, max_tokens, temperature, auth_token)
                                     when "openai"
                                       build_openai(base_url, model, prompt, system_msg, max_tokens, temperature, auth_token)
                                     else
                                       return error("invalid_provider", "unknown provider '#{provider}'")
                                     end

        response = HttpClient.request(method: "POST", uri: uri,
                                      headers: headers, body: request_body,
                                      timeout_ms: request.timeout_ms || 60_000)

        parsed = response.body_json
        if response.status.between?(200, 299) && parsed
          {
            exit_code:   0,
            output_json: shape_output(provider, parsed, model),
            stdout:      "",
            stderr:      "",
            error_type:  nil, error_message: nil
          }
        else
          {
            exit_code:     response.status,
            output_json:   nil,
            stdout:        parsed ? JSON.dump(parsed) : response.body_text,
            stderr:        "",
            error_type:    "llm_error",
            error_message: "HTTP #{response.status}: #{provider_error_message(parsed) || first_line(response.body_text)}"
          }
        end
      rescue HttpClient::TimeoutError => e
        error("timeout", "LLM timeout: #{e.message}")
      rescue HttpClient::RequestError => e
        error("llm_error", e.message)
      rescue ArgumentError => e
        error("llm_error", e.message)
      end

      def build_anthropic(base, model, prompt, system_msg, max_tokens, temperature, token)
        body = {
          "model"      => model,
          "max_tokens" => max_tokens,
          "messages"   => [{ "role" => "user", "content" => prompt }]
        }
        body["system"] = system_msg unless system_msg.empty?
        body["temperature"] = temperature if temperature

        uri = URI.join(base.sub(%r{/+\z}, "") + "/", "v1/messages")
        headers = {
          "content-type"      => "application/json",
          "anthropic-version" => ANTHROPIC_VERSION
        }
        headers["x-api-key"] = token if token && !token.empty?
        [JSON.dump(body), uri, headers]
      end

      def build_openai(base, model, prompt, system_msg, max_tokens, temperature, token)
        messages = []
        messages << { "role" => "system", "content" => system_msg } unless system_msg.empty?
        messages << { "role" => "user", "content" => prompt }

        body = {
          "model"      => model,
          "max_tokens" => max_tokens,
          "messages"   => messages
        }
        body["temperature"] = temperature if temperature

        uri = URI.join(base.sub(%r{/+\z}, "") + "/", "v1/chat/completions")
        headers = { "content-type" => "application/json" }
        headers["authorization"] = "Bearer #{token}" if token && !token.empty?
        [JSON.dump(body), uri, headers]
      end

      def shape_output(provider, parsed, model)
        case provider
        when "anthropic"
          text = (parsed["content"] || []).filter_map { |b| b["text"] if b["type"] == "text" }.join
          usage = parsed["usage"] || {}
          {
            "text"        => text,
            "model"       => parsed["model"] || model,
            "usage"       => { "input_tokens" => usage["input_tokens"], "output_tokens" => usage["output_tokens"] },
            "stop_reason" => parsed["stop_reason"]
          }
        when "openai"
          choice = (parsed["choices"] || []).first || {}
          msg = choice["message"] || {}
          usage = parsed["usage"] || {}
          {
            "text"        => msg["content"].to_s,
            "model"       => parsed["model"] || model,
            "usage"       => { "input_tokens" => usage["prompt_tokens"], "output_tokens" => usage["completion_tokens"] },
            "stop_reason" => choice["finish_reason"]
          }
        end
      end

      def provider_error_message(parsed)
        return nil unless parsed.is_a?(Hash)

        if parsed["error"].is_a?(Hash)
          parsed["error"]["message"]
        elsif parsed["error"].is_a?(String)
          parsed["error"]
        end
      end

      def resolve_token(request)
        auth = request.field("auth")
        return nil unless auth

        (request.env || {})[auth.secret_name]
      end

      # Build the subprocess env from the interface's `env` / `env-forward`
      # / `secret` declarations. Returns `[extra_env, sandbox_env]` where
      # `sandbox_env` is true when ANY of the three is declared — the
      # opt-in signal that the spawn should run with
      # `unsetenv_others: true` so a prompt-injection can't exfiltrate
      # whatever else the daemon was started with.
      #
      # Resolution rules:
      #   `env KEY VALUE`     — static (already templated by BlockExecutor)
      #   `env-forward KEY`   — pass through daemon ENV[KEY] if present
      #   `secret <NAME>`     — read resolved value from request.env (the
      #                          orchestrator's secret resolver already
      #                          populated it via BlockExecutor.build_env)
      def build_subprocess_env(request)
        env_static  = request.field("env")
        env_static  = env_static.is_a?(Hash) ? env_static : {}
        env_forward = Array(request.field("env-forward"))
        secret_refs = Array(request.field("secret"))
        sandbox_env = !env_static.empty? || !env_forward.empty? || !secret_refs.empty?

        extra = {}
        env_static.each { |k, v| extra[k.to_s] = v.to_s }
        env_forward.each do |key|
          v = ENV[key]
          extra[key] = v.to_s if v
        end
        request_env = request.env || {}
        secret_refs.each do |name|
          v = request_env[name]
          extra[name] = v.to_s if v
        end

        [extra, sandbox_env]
      end

      def parse_int(value, default)
        return default if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        Integer(value.to_s)
      rescue ArgumentError, TypeError
        default
      end

      def parse_float(value)
        return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        Float(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def first_line(s)
        s.lines.first.to_s.chomp
      end

      def error(type, message)
        { exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message }
      end
    end
  end
end
