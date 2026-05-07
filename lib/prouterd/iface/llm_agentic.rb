require "uri"
require "json"
require_relative "http_client"

module Prouterd
  module Iface
    # Multi-turn tool-use driver for `interface llm` blocks declaring
    # `agentic on`. Drives the Anthropic /v1/messages tools API in a
    # loop: model emits tool_use → driver dispatches via the supplied
    # callback → tool_result is appended to the conversation → repeat
    # until the model returns plain text, the per-block tool-call
    # limit is reached, or an error fires.
    #
    # OpenAI provider isn't wired here yet — its function-calling shape
    # differs enough to deserve its own driver later. Subprocess
    # providers (codex_cli/claude_cli) handle multi-turn natively
    # through their own CLI; agentic mode for those is out of scope.
    #
    # Output JSON shape (returned to the orchestrator as block output):
    #   {
    #     "text"        => "<final assistant text, concatenated>",
    #     "model"       => "<model id>",
    #     "usage"       => { "input_tokens" => N, "output_tokens" => M },
    #     "stop_reason" => "end_turn" | "max_turns" | "max_tokens" | ...,
    #     "tool_calls"  => [{ "name" => ..., "input" => {...}, "output" => {...} }, ...],
    #     "turns"       => N
    #   }
    module LlmAgentic
      module_function

      DEFAULT_MAX_TURNS = 12
      DEFAULT_TIMEOUT_MS = 120_000
      ANTHROPIC_VERSION = "2023-06-01".freeze

      # Build the input_schema for a tool from its declared args. We keep
      # it intentionally weak — every arg is a required string — because
      # the full type system would require fields we don't currently
      # carry on AST::Tool. Operators tighten via prompt engineering.
      def schema_for(tool)
        properties = tool.args.each_with_object({}) do |arg, h|
          h[arg] = { "type" => "string", "description" => "" }
        end
        {
          "type"       => "object",
          "properties" => properties,
          "required"   => tool.args
        }
      end

      def tool_definitions(tools)
        tools.map do |t|
          { "name" => t.name, "description" => t.description.to_s, "input_schema" => schema_for(t) }
        end
      end

      # Drive one agentic block. Required keyword args:
      #   model        — Anthropic model id
      #   base_url     — provider base URL (lets tests / proxies override)
      #   api_key      — bearer; passed in `x-api-key`
      #   prompt       — initial user message
      #   system_msg   — optional system prompt
      #   max_tokens   — per-turn token cap
      #   max_turns    — hard ceiling on tool-use round-trips
      #   tools        — Array<AST::Tool>
      #   dispatcher   — Proc<(name:String, input:Hash) -> Hash{output_json,error_type?,error_message?}>
      #   timeout_ms   — per-HTTP-call budget (defaults to 120s)
      def run(model:, base_url:, api_key:, prompt:, system_msg:,
              max_tokens:, max_turns:, tools:, dispatcher:, timeout_ms: nil)
        max_turns = (max_turns || DEFAULT_MAX_TURNS).to_i
        max_turns = DEFAULT_MAX_TURNS if max_turns < 1
        budget_timeout = timeout_ms || DEFAULT_TIMEOUT_MS

        messages = [{ "role" => "user", "content" => prompt }]
        tool_defs = tool_definitions(tools)
        usage_in = 0
        usage_out = 0
        tool_calls = []
        final_text = ""
        stop_reason = nil
        turns = 0

        loop do
          response = call_anthropic(
            base_url: base_url, model: model, api_key: api_key,
            system_msg: system_msg, max_tokens: max_tokens,
            tools: tool_defs, messages: messages, timeout_ms: budget_timeout
          )

          unless response[:ok]
            return failure(error_type: response[:error_type] || "llm_error",
                            message:   response[:error_message] || "agentic provider request failed",
                            usage_in: usage_in, usage_out: usage_out,
                            tool_calls: tool_calls, turns: turns)
          end

          parsed = response[:body]
          turn_usage = parsed["usage"] || {}
          usage_in  += (turn_usage["input_tokens"]  || 0).to_i
          usage_out += (turn_usage["output_tokens"] || 0).to_i
          stop_reason = parsed["stop_reason"]

          content_blocks = Array(parsed["content"])
          tool_use_blocks = content_blocks.select { |b| b.is_a?(Hash) && b["type"] == "tool_use" }
          text_blocks     = content_blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }

          # Always preserve the assistant turn so the next user turn's
          # tool_result blocks have a matching tool_use_id ancestor.
          messages << { "role" => "assistant", "content" => content_blocks }

          if tool_use_blocks.empty?
            final_text = text_blocks.filter_map { |b| b["text"] }.join
            break
          end

          turns += 1
          if turns > max_turns
            stop_reason = "max_turns"
            final_text = text_blocks.filter_map { |b| b["text"] }.join
            break
          end

          tool_results = tool_use_blocks.map do |tu|
            outcome = invoke_tool(dispatcher, tu["name"], tu["input"] || {})
            tool_calls << {
              "name"   => tu["name"],
              "input"  => tu["input"] || {},
              "output" => outcome[:output_json],
              "error"  => outcome[:error_type]
            }.compact

            payload = if outcome[:error_type]
                        JSON.dump(error: outcome[:error_type], message: outcome[:error_message])
                      else
                        JSON.dump(outcome[:output_json] || {})
                      end

            block = {
              "type"          => "tool_result",
              "tool_use_id"   => tu["id"],
              "content"       => payload
            }
            block["is_error"] = true if outcome[:error_type]
            block
          end
          messages << { "role" => "user", "content" => tool_results }
        end

        {
          ok:          true,
          output_json: {
            "text"        => final_text,
            "model"       => model,
            "usage"       => { "input_tokens" => usage_in, "output_tokens" => usage_out },
            "stop_reason" => stop_reason,
            "tool_calls"  => tool_calls,
            "turns"       => turns
          },
          error_type:    nil,
          error_message: nil,
          stdout:        "",
          stderr:        "",
          exit_code:     0
        }
      end

      # Single dispatcher invocation, normalised so the loop never
      # blows up on a tool that throws — the LLM should see an error
      # payload and decide what to do next.
      def invoke_tool(dispatcher, name, input)
        outcome = dispatcher.call(name: name, input: input)
        outcome.is_a?(Hash) ? outcome : { error_type: "tool_dispatch", error_message: outcome.to_s }
      rescue StandardError => e
        { error_type: "tool_dispatch", error_message: "#{e.class}: #{e.message}" }
      end

      def call_anthropic(base_url:, model:, api_key:, system_msg:, max_tokens:,
                         tools:, messages:, timeout_ms:)
        uri = URI.join(base_url.sub(%r{/+\z}, "") + "/", "v1/messages")
        body = {
          "model"      => model,
          "max_tokens" => max_tokens,
          "tools"      => tools,
          "messages"   => messages
        }
        body["system"] = system_msg unless system_msg.to_s.empty?

        headers = {
          "content-type"      => "application/json",
          "anthropic-version" => ANTHROPIC_VERSION
        }
        headers["x-api-key"] = api_key if api_key && !api_key.empty?

        response = HttpClient.request(
          method: "POST", uri: uri,
          headers: headers, body: JSON.dump(body),
          timeout_ms: timeout_ms
        )

        if response.status.between?(200, 299) && response.body_json
          { ok: true, body: response.body_json }
        else
          err_msg = response.body_json.is_a?(Hash) && response.body_json["error"].is_a?(Hash) ?
                    response.body_json["error"]["message"] :
                    response.body_text.lines.first.to_s.chomp
          { ok: false, error_type: "llm_error",
            error_message: "HTTP #{response.status}: #{err_msg}" }
        end
      rescue HttpClient::TimeoutError => e
        { ok: false, error_type: "timeout", error_message: e.message }
      rescue HttpClient::RequestError => e
        { ok: false, error_type: "llm_error", error_message: e.message }
      end

      def failure(error_type:, message:, usage_in:, usage_out:, tool_calls:, turns:)
        {
          ok:            false,
          output_json:   {
            "text"        => "",
            "usage"       => { "input_tokens" => usage_in, "output_tokens" => usage_out },
            "tool_calls"  => tool_calls,
            "turns"       => turns
          },
          error_type:    error_type,
          error_message: message,
          stdout:        "",
          stderr:        message,
          exit_code:     nil
        }
      end
    end
  end
end
