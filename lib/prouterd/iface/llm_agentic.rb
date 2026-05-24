# frozen_string_literal: true

require "uri"
require "json"
require "open3"
require_relative "http_client"

module Prouterd
  module Iface
    # Multi-turn tool-use driver for `interface llm` blocks declaring
    # `agentic on`. Two transports:
    #
    # - HTTP (`provider anthropic`): /v1/messages tools API. Each turn
    #   round-trips a JSON body; tool_use blocks are dispatched and
    #   tool_result content appended to messages.
    #
    # - Subprocess (`provider codex_cli` / `claude_cli`): single
    #   persistent process per agentic block. Stdin carries the
    #   user/tool messages in JSONL; stdout emits item-completed /
    #   function-call / turn-completed events. Same dispatch closure
    #   used by both transports.
    #
    # OpenAI HTTP provider isn't wired here yet — its function-calling
    # shape differs enough to deserve its own branch.
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
      #
      # MCP tool refs (Iface::McpToolRef) carry the schema verbatim
      # from the server's `tools/list`; we honour it as-is.
      def schema_for(tool)
        if tool.respond_to?(:input_schema) && tool.input_schema.is_a?(Hash)
          return tool.input_schema
        end

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
          { "name" => tool_facing_name(t),
            "description" => t.description.to_s,
            "input_schema" => schema_for(t) }
        end
      end

      # MCP tools use their full `<iface>.<name>` form on the wire so
      # the orchestrator's dispatcher can route them. AST::Tool just
      # uses the bare `name`.
      def tool_facing_name(tool)
        tool.respond_to?(:full_name) ? tool.full_name : tool.name
      end

      # Drive one agentic block. Required keyword args:
      #   provider     — "anthropic" | "codex_cli" | "claude_cli"
      #   model        — provider model id
      #   base_url     — Anthropic base URL (HTTP path only)
      #   api_key      — bearer (HTTP path only)
      #   binary       — CLI path (subprocess path only)
      #   home         — HOME for the subprocess (subscription state dir)
      #   sandbox      — `-s <mode>` value (subprocess path only)
      #   prompt       — initial user message
      #   system_msg   — optional system prompt
      #   max_tokens   — per-turn token cap (HTTP) or hint (subprocess)
      #   max_turns    — hard ceiling on tool-use round-trips
      #   tools        — Array<AST::Tool>
      #   dispatcher   — Proc<(name:String, input:Hash) -> Hash>
      #   timeout_ms   — per-call budget
      def run(provider: "anthropic", model:, base_url: nil, api_key: nil,
              binary: nil, home: nil, sandbox: nil,
              cwd: nil, reasoning_effort: nil,
              extra_env: {}, sandbox_env: false,
              prompt:, system_msg:, max_tokens:, max_turns:, tools:, dispatcher:,
              timeout_ms: nil)
        if %w[codex_cli claude_cli].include?(provider)
          return run_subprocess(
            provider: provider, model: model, binary: binary, home: home,
            sandbox: sandbox, cwd: cwd, reasoning_effort: reasoning_effort,
            extra_env: extra_env, sandbox_env: sandbox_env,
            prompt: prompt, system_msg: system_msg,
            max_turns: max_turns, tools: tools, dispatcher: dispatcher,
            timeout_ms: timeout_ms
          )
        end

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

      # Subprocess multi-turn loop for `provider codex_cli` /
      # `claude_cli`. One persistent process per block; stdin carries
      # user / tool-output messages in JSONL; stdout emits item-completed
      # / function-call / turn-completed events. Tool dispatch happens
      # in-process via the same closure the HTTP path uses.
      #
      # Wire format (the conservative subset of what Codex / Claude CLI
      # emit; the binary is invoked with `--json` / `--protocol jsonl`
      # depending on which CLI you point at):
      #
      #   in:  {"role":"user","content":"<prompt>","tools":[...],"system":"..."}
      #   out: {"type":"item.completed","item":{"type":"message",
      #                                         "content":[{"type":"text","text":"..."}]}}
      #   out: {"type":"item.completed","item":{"type":"function_call",
      #                                         "id":"call_X","name":"X","arguments":"<json>"}}
      #   in:  {"type":"function_call_output","call_id":"call_X","output":"<json>"}
      #   out: {"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":M},
      #                                  "stop_reason":"end_turn"}
      #
      # If your CLI's JSONL shape diverges, override the recognisers in
      # extract_event_text / extract_event_function_call.
      def run_subprocess(provider:, model:, binary:, home:, sandbox:, prompt:, system_msg:,
                         max_turns:, tools:, dispatcher:, timeout_ms:,
                         cwd: nil, reasoning_effort: nil,
                         extra_env: {}, sandbox_env: false)
        max_turns = (max_turns || DEFAULT_MAX_TURNS).to_i
        max_turns = DEFAULT_MAX_TURNS if max_turns < 1
        deadline = Time.now + ((timeout_ms || DEFAULT_TIMEOUT_MS) / 1000.0)

        argv = LlmSubprocess.build_argv(provider, binary, model, sandbox,
                                         reasoning_effort: reasoning_effort)
        env  = LlmSubprocess.build_env(home).merge(extra_env || {})
        resolved_cwd = LlmSubprocess.resolve_cwd(cwd)
        if cwd && resolved_cwd.nil?
          return failure(error_type: "invalid_cwd",
                          message:   "#{provider} cwd does not exist: #{cwd}",
                          usage_in: 0, usage_out: 0, tool_calls: [], turns: 0)
        end

        unless LlmSubprocess.cli_available?(argv.first)
          return failure(error_type: "missing_dependency",
                          message:   "#{provider} binary '#{argv.first}' not found on PATH",
                          usage_in: 0, usage_out: 0, tool_calls: [], turns: 0)
        end

        tool_defs = tool_definitions(tools)
        usage_in = 0
        usage_out = 0
        tool_calls = []
        final_text = String.new(encoding: Encoding::UTF_8)
        stop_reason = nil
        turns = 0
        stderr_buf = String.new(encoding: Encoding::UTF_8)

        options = LlmSubprocess.popen_options(cwd: resolved_cwd, sandbox_env: sandbox_env)
        popen_args = options.empty? ? [env, *argv] : [env, *argv, options]
        Open3.popen3(*popen_args) do |stdin, stdout, stderr, wait_thr|
          err_thread = Thread.new { stderr_buf << stderr.read.to_s }

          # First message: prompt + tools + system. Subsequent messages
          # are tool outputs only; the CLI carries the conversation
          # state in the persistent process.
          first_msg = { "role" => "user", "content" => prompt, "tools" => tool_defs }
          first_msg["system"] = system_msg unless system_msg.to_s.empty?
          stdin.puts(JSON.dump(first_msg))
          stdin.flush

          pending_tool_calls = []

          stdout.each_line do |raw|
            if Time.now > deadline
              Process.kill("TERM", wait_thr.pid) rescue nil
              return failure(error_type: "timeout",
                              message: "#{provider} agentic timed out",
                              usage_in: usage_in, usage_out: usage_out,
                              tool_calls: tool_calls, turns: turns)
            end

            event = (JSON.parse(raw) rescue nil)
            next unless event.is_a?(Hash)

            text_chunk = extract_event_text(event)
            final_text << text_chunk if text_chunk

            fc = extract_event_function_call(event)
            pending_tool_calls << fc if fc

            if (u = event["usage"]).is_a?(Hash)
              usage_in  += (u["input_tokens"]  || u["prompt_tokens"]    || 0).to_i
              usage_out += (u["output_tokens"] || u["completion_tokens"] || 0).to_i
            end

            if turn_completed?(event)
              # End of one model turn. If the model emitted function
              # calls, dispatch them and feed outputs back, else we're
              # done.
              if pending_tool_calls.empty?
                stop_reason = event["stop_reason"] || "end_turn"
                break
              end

              turns += 1
              if turns > max_turns
                stop_reason = "max_turns"
                break
              end

              pending_tool_calls.each do |fc|
                args_hash = (fc["arguments"].is_a?(String) ? (JSON.parse(fc["arguments"]) rescue {}) : (fc["arguments"] || {}))
                outcome = invoke_tool(dispatcher, fc["name"], args_hash)
                tool_calls << {
                  "name" => fc["name"], "input" => args_hash,
                  "output" => outcome[:output_json], "error" => outcome[:error_type]
                }.compact

                payload = if outcome[:error_type]
                            JSON.dump(error: outcome[:error_type], message: outcome[:error_message])
                          else
                            JSON.dump(outcome[:output_json] || {})
                          end
                stdin.puts(JSON.dump(
                  "type" => "function_call_output",
                  "call_id" => fc["id"] || fc["call_id"],
                  "output"  => payload
                ))
                stdin.flush
              end
              pending_tool_calls.clear
            end
          end

          stdin.close rescue nil
          err_thread.join
          status = wait_thr.value
          unless status.success? || stop_reason
            return failure(error_type: "llm_error",
                            message: "#{provider} exited #{status.exitstatus}: #{stderr_buf.lines.first.to_s.chomp}",
                            usage_in: usage_in, usage_out: usage_out,
                            tool_calls: tool_calls, turns: turns)
          end
        end

        {
          ok: true,
          output_json: {
            "text"        => final_text,
            "model"       => model,
            "usage"       => { "input_tokens" => usage_in, "output_tokens" => usage_out },
            "stop_reason" => stop_reason || "end_turn",
            "tool_calls"  => tool_calls,
            "turns"       => turns
          },
          error_type: nil, error_message: nil,
          stdout: "", stderr: stderr_buf, exit_code: 0
        }
      end

      # Recognise a turn-completion marker in any reasonable JSONL
      # shape. Codex emits `{"type":"turn.completed", ...}`, Claude CLI
      # emits `{"type":"message_stop", ...}`. Override here if your
      # binary disagrees.
      def turn_completed?(event)
        %w[turn.completed message_stop turn_complete].include?(event["type"])
      end

      # Find user-visible text in an item-completed event. Returns the
      # text fragment (string) or nil.
      def extract_event_text(event)
        if event["delta"].is_a?(Hash) && event["delta"]["text"].is_a?(String)
          return event["delta"]["text"]
        end
        item = event["item"]
        if item.is_a?(Hash) && item["type"] == "message"
          parts = Array(item["content"])
          text = parts.filter_map { |p| p["text"] if p.is_a?(Hash) && p["text"].is_a?(String) }.join
          return text unless text.empty?
        end
        nil
      end

      # Find a function-call item in an event. Returns
      # {id, name, arguments} (arguments may be a JSON string OR a
      # parsed hash) or nil.
      def extract_event_function_call(event)
        item = event["item"]
        return nil unless item.is_a?(Hash) && item["type"] == "function_call"

        { "id"        => item["id"] || item["call_id"],
          "name"      => item["name"],
          "arguments" => item["arguments"] }
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
