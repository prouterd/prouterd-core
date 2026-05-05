require "net/http"
require "uri"
require "json"

module Prouterd
  module Iface
    # Caller for `interface llm`. Invoked by `Runner::CallRunner` when a
    # block references an outbound llm interface.
    #
    # Reads from `request.type_fields` (orchestrator merged the iface body
    # and the templated per-call fields):
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
    # Note: the full provider response is intentionally NOT echoed back into
    # `output_json`. Some providers include the prompt or other context in
    # error responses, and that body would otherwise flow into the run
    # context for downstream blocks. Callers that need the raw response
    # should inspect step logs (which are redacted).
    class LlmCaller
      DEFAULT_MAX_TOKENS = 1024

      DEFAULT_BASE_URL = {
        "anthropic" => "https://api.anthropic.com",
        "openai"    => "https://api.openai.com"
      }.freeze

      ANTHROPIC_VERSION = "2023-06-01".freeze

      def run(request)
        started_at = Time.now.utc
        result = perform_run(request)
        finished_at = Time.now.utc
        Runner::ExecutionResult.new(
          exit_code:     result[:exit_code],
          stdout:        result[:stdout].to_s,
          stderr:        result[:stderr].to_s,
          output_json:   result[:output_json],
          artifacts:     [],
          error_type:    result[:error_type],
          error_message: result[:error_message],
          duration_ms:   ((finished_at - started_at) * 1000).to_i,
          started_at:    started_at.iso8601(3),
          finished_at:   finished_at.iso8601(3)
        )
      end

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

        response = perform(uri, request_body, headers, request.timeout_ms)
        body = response.body.to_s

        parsed = nil
        begin
          parsed = JSON.parse(body) unless body.empty?
        rescue JSON::ParserError
          # leave parsed nil
        end

        if response.code.to_i.between?(200, 299) && parsed
          {
            exit_code:   0,
            output_json: shape_output(provider, parsed, model),
            stdout:      "",
            stderr:      "",
            error_type:  nil, error_message: nil
          }
        else
          {
            exit_code:     response.code.to_i,
            output_json:   nil,
            stdout:        parsed ? JSON.dump(parsed) : body,
            stderr:        "",
            error_type:    "llm_error",
            error_message: "HTTP #{response.code}: #{provider_error_message(parsed) || first_line(body)}"
          }
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        error("timeout", "LLM timeout: #{e.message}")
      rescue StandardError => e
        error("llm_error", "#{e.class}: #{e.message}")
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
        { exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message }
      end
    end
  end
end
