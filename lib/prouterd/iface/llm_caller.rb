require "net/http"
require "uri"
require "json"

module Prouterd
  module Iface
    # Caller for `interface llm`. Invoked by `Runner::CallRunner` when a
    # block references an outbound llm interface.
    #
    # Reads from the resolved AST::Interface:
    #   * provider — "anthropic" | "openai"
    #   * model    — model identifier (e.g. "claude-haiku-4-5-20251001")
    #   * auth     — AST::Auth with secret_name; resolved value is the API key
    #   * base-url — optional override (defaults to the provider's public URL)
    #
    # Reads from per-call type_fields (already templated):
    #   * prompt      — required user prompt
    #   * system      — optional system prompt
    #   * max-tokens  — string, parsed as int (default "1024")
    #   * temperature — optional, parsed as float
    #
    # Output JSON shape (provider-agnostic):
    #   { "text" => "...", "model" => "...",
    #     "usage" => { "input_tokens" => N, "output_tokens" => M },
    #     "stop_reason" => "...", "raw" => <full provider response> }
    class LlmCaller
      DEFAULT_MAX_TOKENS = 1024

      DEFAULT_BASE_URL = {
        "anthropic" => "https://api.anthropic.com",
        "openai"    => "https://api.openai.com"
      }.freeze

      ANTHROPIC_VERSION = "2023-06-01".freeze

      CallerResult = Struct.new(
        :exit_code, :output_json, :stdout, :stderr,
        :error_type, :error_message,
        keyword_init: true
      )

      def initialize(secret_resolver: nil)
        @secret_resolver = secret_resolver
      end

      def call(iface:, call_fields:, secrets: {}, timeout_ms: nil)
        provider = iface.type_fields["provider"].to_s
        model    = iface.type_fields["model"].to_s

        return error("invalid_interface", "interface '#{iface.name}' missing provider") if provider.empty?
        return error("invalid_interface", "interface '#{iface.name}' missing model")    if model.empty?

        prompt  = call_fields["prompt"].to_s
        return error("invalid_call", "block missing 'prompt'") if prompt.empty?

        system_msg  = call_fields["system"].to_s
        max_tokens  = parse_int(call_fields["max-tokens"], DEFAULT_MAX_TOKENS)
        temperature = parse_float(call_fields["temperature"])

        auth_token = resolve_token(iface, secrets)

        base_url = iface.type_fields["base-url"]
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

        response = perform(uri, request_body, headers, timeout_ms)
        body = response.body.to_s

        parsed = nil
        begin
          parsed = JSON.parse(body) unless body.empty?
        rescue JSON::ParserError
          # leave parsed nil; raw body becomes stdout
        end

        if response.code.to_i.between?(200, 299) && parsed
          CallerResult.new(
            exit_code: 0,
            output_json: shape_output(provider, parsed, model),
            stdout: "",
            stderr: "",
            error_type: nil,
            error_message: nil
          )
        else
          CallerResult.new(
            exit_code: response.code.to_i,
            output_json: nil,
            stdout: parsed ? JSON.dump(parsed) : body,
            stderr: "",
            error_type: "llm_error",
            error_message: "HTTP #{response.code}: #{provider_error_message(parsed) || first_line(body)}"
          )
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        error("timeout", "LLM timeout: #{e.message}")
      rescue StandardError => e
        error("llm_error", "#{e.class}: #{e.message}")
      end

      private

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
            "stop_reason" => parsed["stop_reason"],
            "raw"         => parsed
          }
        when "openai"
          choice = (parsed["choices"] || []).first || {}
          msg = choice["message"] || {}
          usage = parsed["usage"] || {}
          {
            "text"        => msg["content"].to_s,
            "model"       => parsed["model"] || model,
            "usage"       => { "input_tokens" => usage["prompt_tokens"], "output_tokens" => usage["completion_tokens"] },
            "stop_reason" => choice["finish_reason"],
            "raw"         => parsed
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

      def resolve_token(iface, secrets)
        auth = iface.type_fields["auth"]
        return nil unless auth

        secrets[auth.secret_name]
      end

      def perform(uri, body, headers, timeout_ms)
        request = Net::HTTP::Post.new(uri.request_uri)
        request.body = body
        headers.each { |k, v| request[k] = v }

        Net::HTTP.start(uri.hostname, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: timeout_seconds(timeout_ms),
                        read_timeout: timeout_seconds(timeout_ms)) do |http|
          http.request(request)
        end
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

      def timeout_seconds(timeout_ms)
        return 60 unless timeout_ms

        [(timeout_ms.to_f / 1000.0), 1].max
      end

      def first_line(s)
        s.lines.first.to_s.chomp
      end

      def error(type, message)
        CallerResult.new(
          exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message
        )
      end
    end
  end
end
