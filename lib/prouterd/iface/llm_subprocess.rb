# frozen_string_literal: true

require "open3"
require "json"

module Prouterd
  module Iface
    # Subprocess-based LLM provider — used by `provider codex_cli` and
    # `provider claude_cli` on `interface llm`. Runs a local CLI binary
    # whose authentication lives in a subscription token stored on disk
    # rather than a per-request API key (substantial cost difference at
    # high request rates against subscription pricing).
    #
    # The driver:
    #   1. Builds an argv per-provider convention.
    #   2. Spawns the binary with `Open3.popen3`, writing the prompt to
    #      stdin and closing it.
    #   3. Reads stdout line-by-line, parsing each as JSON. Lines that
    #      don't parse are treated as plain stdout text and concatenated
    #      into the run's stderr buffer (operator visibility) — they do
    #      not count toward the response.
    #   4. Aggregates `text`/usage out of recognised event shapes:
    #      * `{"type":"item.completed","item":{"type":"message",
    #          "content":[{"text":"..."}]}}`  — codex CLI
    #      * `{"type":"turn.completed","usage":{...}}`             — codex CLI
    #      * `{"type":"message_delta","delta":{"text":"..."}}`     — claude CLI
    #      * `{"text":"..."}` / `{"content":"..."}`                — fallback
    #      * any event with `usage.input_tokens` / `output_tokens` (or
    #        `prompt_tokens` / `completion_tokens`)                 — usage
    #   5. Returns the canonical {text, model, usage, stop_reason} shape
    #      identical to the HTTP providers.
    #
    # Failure modes: missing binary -> error_type "missing_dependency";
    # non-zero exit -> "llm_error"; timeout -> "timeout".
    module LlmSubprocess
      module_function

      DEFAULT_TIMEOUT_MS = 120_000

      def call(provider:, model:, binary:, home:, sandbox:, prompt:, system_msg:, timeout_ms:,
               cwd: nil, reasoning_effort: nil, extra_env: {}, sandbox_env: false,
               stream: false, stream_sink: nil)
        argv, stdin_text = build_invocation(provider, binary, model, sandbox, prompt, system_msg,
                                             reasoning_effort: reasoning_effort,
                                             stream: stream)
        env = build_env(home).merge(extra_env || {})
        resolved_cwd = resolve_cwd(cwd)
        if cwd && resolved_cwd.nil?
          return {
            exit_code: nil, output_json: nil, stdout: "", stderr: "",
            error_type: "invalid_cwd",
            error_message: "#{provider} cwd does not exist: #{cwd}"
          }
        end

        unless cli_available?(argv.first)
          return {
            exit_code: nil, output_json: nil, stdout: "", stderr: "",
            error_type: "missing_dependency",
            error_message: "#{provider} binary '#{argv.first}' not found on PATH (set `binary <path>` on the interface or PROUTERD_#{provider.upcase}_BIN env)"
          }
        end

        stdout_lines, stderr_text, status = run_subprocess(env, argv, stdin_text, timeout_ms || DEFAULT_TIMEOUT_MS,
                                                            cwd: resolved_cwd, sandbox_env: sandbox_env,
                                                            stream_sink: stream_sink)

        if status == :timeout
          return { exit_code: nil, output_json: nil, stdout: "", stderr: stderr_text,
                   error_type: "timeout",
                   error_message: "#{provider} timed out after #{timeout_ms || DEFAULT_TIMEOUT_MS}ms" }
        end

        # Output protocol differs by provider — codex emits JSONL events,
        # claude (-p mode) emits one wrapper JSON object on stdout (or
        # JSONL when `--output-format stream-json` is active).
        text, usage, stop_reason, raw_stderr_extra =
          parse_output(provider, stdout_lines, stream: stream)
        stderr_combined = [stderr_text, raw_stderr_extra].reject(&:empty?).join

        if !status.success?
          # Preserve any text / usage the model emitted before the
          # subprocess died. Codex/Claude can hit a contract violation
          # or rate limit mid-turn and still have streamed partial
          # output; the operator wants to see it on the failed step
          # row. Downstream context propagation is gated on success in
          # BlockExecutor, so this only affects persistence.
          partial = build_partial_output(text, model, usage, stop_reason)
          return {
            exit_code:     status.exitstatus,
            output_json:   partial,
            stdout:        "",
            stderr:        stderr_combined,
            error_type:    "llm_error",
            error_message: "#{provider} exited #{status.exitstatus}: #{stderr_combined.lines.first.to_s.chomp}"
          }
        end

        {
          exit_code:   0,
          output_json: {
            "text"        => text,
            "model"       => model,
            "usage"       => usage,
            "stop_reason" => stop_reason
          },
          stdout:        "",
          stderr:        stderr_combined,
          error_type:    nil,
          error_message: nil
        }
      end

      # Returns [argv, stdin_text]. Per-provider: codex_cli takes the
      # prompt via stdin in a JSONL-friendly form; claude_cli (Claude
      # Code) takes the prompt as the positional arg of `-p` and reads
      # nothing from stdin.
      def build_invocation(provider, binary, model, sandbox, prompt, system_msg,
                           reasoning_effort: nil, stream: false)
        bin = resolve_binary(provider, binary)
        case provider
        when "codex_cli"
          # Codex CLI emits JSONL events under `--json` regardless of
          # whether the operator opted into streaming on the prouterd
          # side — the `stream:` flag here just controls whether the
          # driver tees each line into the per-step log table as it
          # arrives, not the codex invocation itself.
          argv = [bin, "exec", "--json"]
          argv += ["-m", model] unless model.to_s.empty?
          argv += ["-s", sandbox] if sandbox && !sandbox.empty?
          argv += codex_reasoning_args(reasoning_effort)
          stdin_text = build_codex_stdin(prompt, system_msg)
        when "claude_cli"
          # reasoning_effort is a codex-only concept; silently ignored
          # for Claude Code (it has its own thinking-mode toggles via
          # a different API).
          argv = build_argv_claude(bin, model, prompt, system_msg, stream: stream)
          stdin_text = ""
        else
          raise ArgumentError, "unknown subprocess provider '#{provider}'"
        end
        [argv, stdin_text]
      end

      # Back-compat for the multi-turn agentic loop (Iface::LlmAgentic),
      # which speaks codex's persistent-stdin JSONL protocol. Claude
      # Code CLI's `-p` mode is one-shot — multi-turn would need
      # `--resume <session>` chaining, which is a different driver.
      # Validator rejects `agentic on` + `provider claude_cli` at apply
      # time so this method is only hit for codex_cli.
      def build_argv(provider, binary, model, sandbox, reasoning_effort: nil)
        unless provider == "codex_cli"
          raise ArgumentError, "build_argv only supports codex_cli; " \
                               "claude_cli requires the per-call build_invocation path"
        end

        bin = resolve_binary(provider, binary)
        argv = [bin, "exec", "--json"]
        argv += ["-m", model] unless model.to_s.empty?
        argv += ["-s", sandbox] if sandbox && !sandbox.empty?
        argv += codex_reasoning_args(reasoning_effort)
        argv
      end

      # `-c model_reasoning_effort=<level>` is codex's stable config-
      # override flag; works across recent versions without requiring
      # a top-level `--reasoning-effort` switch the CLI may or may not
      # expose. Returns [] when no override is requested so the user's
      # CLI default applies.
      def codex_reasoning_args(level)
        return [] if level.nil? || level.to_s.empty?

        ["-c", "model_reasoning_effort=#{level}"]
      end

      def resolve_cwd(cwd)
        return nil if cwd.nil? || cwd.to_s.empty?

        File.directory?(cwd) ? cwd : nil
      end

      # Combine the optional spawn options into a single hash for
      # Open3.popen3. Empty hash means "no options at all" — keeping
      # the old call shape Ruby-compatible across versions and avoiding
      # an empty hash being treated as a positional arg.
      def popen_options(cwd: nil, sandbox_env: false)
        opts = {}
        opts[:chdir] = cwd if cwd
        opts[:unsetenv_others] = true if sandbox_env
        opts
      end

      # Real Claude Code CLI 2.1.x invocation:
      #   claude -p "<prompt>" --output-format json --model <model>
      #          [--system-prompt "<system>"]
      #
      # `--system-prompt` FULLY replaces Claude Code's default agent
      # system prompt; that's what we want for `interface llm` blocks
      # (no Claude-Code-agent baggage). Without `system_msg` we omit
      # the flag and let Claude Code apply its default — usually fine
      # for one-shot prompts.
      def build_argv_claude(bin, model, prompt, system_msg, stream: false)
        # Claude Code's `-p` print mode requires `--verbose` whenever
        # `--output-format stream-json` is requested (CLI errors out
        # otherwise). Aggregated final text is read from the `type:
        # "result"` event at end-of-stream, same as the single-wrapper
        # JSON shape.
        format = stream ? "stream-json" : "json"
        argv = [bin, "-p", prompt.to_s, "--output-format", format]
        argv += ["--verbose"] if stream
        argv += ["--model", model] unless model.to_s.empty?
        argv += ["--system-prompt", system_msg] if system_msg && !system_msg.to_s.empty?
        argv
      end

      def resolve_binary(provider, binary)
        bin = binary
        bin = nil if bin.respond_to?(:empty?) && bin.empty?
        bin ||= ENV["PROUTERD_#{provider.upcase}_BIN"]
        bin ||= provider == "codex_cli" ? "codex" : "claude"
        bin
      end

      def build_env(home)
        env = {}
        env["HOME"] = home if home && !home.empty?
        env
      end

      def build_codex_stdin(prompt, system_msg)
        if system_msg && !system_msg.empty?
          "[SYSTEM]\n#{system_msg}\n[USER]\n#{prompt}\n"
        else
          "#{prompt}\n"
        end
      end

      def cli_available?(bin)
        return true if bin.start_with?("/") && File.executable?(bin)

        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, bin))
        end
      end

      def run_subprocess(env, argv, stdin_text, timeout_ms, cwd: nil, sandbox_env: false,
                         stream_sink: nil)
        stdout_lines = []
        stderr_buf = String.new(encoding: Encoding::UTF_8)
        status = nil

        deadline = Time.now + (timeout_ms / 1000.0)
        options = popen_options(cwd: cwd, sandbox_env: sandbox_env)
        popen_args = options.empty? ? [env, *argv] : [env, *argv, options]
        Open3.popen3(*popen_args) do |stdin, stdout, stderr, wait_thr|
          stdin.write(stdin_text) rescue nil
          stdin.close rescue nil

          out_thread = Thread.new do
            stdout.each_line do |raw|
              line = raw.chomp
              stdout_lines << line
              # When the operator opted into streaming, hand each line
              # to the per-step log writer immediately — `prouter logs
              # <run_uid> --follow` then sees agent progress without
              # waiting for the subprocess to terminate.
              stream_sink&.call(line, "stdout")
            end
          end
          err_thread = Thread.new { stderr_buf << stderr.read.to_s }

          while wait_thr.alive?
            if Time.now > deadline
              Process.kill("TERM", wait_thr.pid) rescue nil
              sleep 0.05
              Process.kill("KILL", wait_thr.pid) rescue nil
              status = :timeout
              break
            end
            sleep 0.02
          end
          out_thread.join
          err_thread.join
          status ||= wait_thr.value
        end

        [stdout_lines, stderr_buf, status]
      end

      # Build the canonical output shape from parsed pieces, or return
      # nil if the subprocess produced no text and zero token usage.
      # Used on the failure path so a step row only carries a partial
      # output_json when the model actually streamed something — empty
      # failures stay output_json=nil.
      def build_partial_output(text, model, usage, stop_reason)
        text_str = text.to_s
        in_tokens  = (usage["input_tokens"]  if usage.is_a?(Hash)).to_i
        out_tokens = (usage["output_tokens"] if usage.is_a?(Hash)).to_i
        return nil if text_str.empty? && in_tokens.zero? && out_tokens.zero?

        {
          "text"        => text_str,
          "model"       => model,
          "usage"       => usage,
          "stop_reason" => stop_reason
        }
      end

      # Dispatch per-provider stdout shape. `codex_cli` is always
      # JSONL (one event per line). `claude_cli` defaults to a single
      # wrapper JSON object on stdout; `stream: true` flips it to the
      # JSONL `stream-json` shape, where the final assistant text is
      # carried by the `type: "result"` event.
      def parse_output(provider, stdout_lines, stream: false)
        case provider
        when "claude_cli"
          stream ? parse_output_claude_stream(stdout_lines) : parse_output_claude(stdout_lines)
        else
          parse_output_codex(stdout_lines)
        end
      end

      # Claude Code emits ONE JSON wrapper:
      #   {
      #     "type":"result", "subtype":"success",
      #     "is_error":false, "result":"<assistant text>",
      #     "session_id":"...",
      #     "usage":{"input_tokens":N,"output_tokens":M,...},
      #     "total_cost_usd":0.0123,
      #     "model":"claude-..."
      #   }
      # If `--json-schema` is passed, the schema-conformant payload
      # appears under `structured_output`. We don't pass `--json-schema`
      # in v0; downstream contract validation handles shape.
      def parse_output_claude(stdout_lines)
        unparsed = String.new(encoding: Encoding::UTF_8)
        joined = stdout_lines.join("\n")
        parsed = (JSON.parse(joined) rescue nil)
        unless parsed.is_a?(Hash)
          unparsed << joined unless joined.empty?
          return ["", { "input_tokens" => 0, "output_tokens" => 0 }, nil, unparsed]
        end

        text = parsed["result"].to_s
        text = parsed["structured_output"].to_json if parsed["structured_output"]
        usage = parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}
        in_tokens  = (usage["input_tokens"]  || usage["prompt_tokens"]    || 0).to_i
        out_tokens = (usage["output_tokens"] || usage["completion_tokens"] || 0).to_i
        stop_reason = parsed["stop_reason"] || parsed["subtype"]

        [text, { "input_tokens" => in_tokens, "output_tokens" => out_tokens }, stop_reason, unparsed]
      end

      # Claude Code `--output-format stream-json --verbose` emits one
      # JSON event per line. The final assistant text lives in the
      # `type: "result"` event under `result`; usage / model arrive on
      # the same event. Intermediate `type: "assistant"` events carry
      # streaming content blocks — they're surfaced live via the
      # stream_sink callback in run_subprocess but ignored here for
      # aggregation (the result event is canonical).
      def parse_output_claude_stream(stdout_lines)
        unparsed = String.new(encoding: Encoding::UTF_8)
        text = ""
        usage = { "input_tokens" => 0, "output_tokens" => 0 }
        stop_reason = nil
        model = nil

        stdout_lines.each do |raw|
          next if raw.strip.empty?
          event = (JSON.parse(raw) rescue nil)
          unless event.is_a?(Hash)
            unparsed << raw << "\n"
            next
          end

          if event["type"] == "result"
            text = event["result"].to_s if event.key?("result")
            if event["structured_output"]
              text = event["structured_output"].to_json
            end
            u = event["usage"]
            if u.is_a?(Hash)
              usage = {
                "input_tokens"  => (u["input_tokens"]  || u["prompt_tokens"]    || 0).to_i,
                "output_tokens" => (u["output_tokens"] || u["completion_tokens"] || 0).to_i
              }
            end
            stop_reason = event["stop_reason"] || event["subtype"]
            model ||= event["model"]
          end
        end

        [text, usage, stop_reason, unparsed]
      end

      # Codex emits JSONL: one event per line, multiple events per run.
      #
      # Two text shapes coexist here:
      #
      #   * `agent_message` events — codex 0.129+ wraps the assistant's
      #     reply as `{type:"item.completed", item:{type:"agent_message",
      #     text:"..."}}`. Older codex used the flat `{type:"agent_message",
      #     text:"..."}` (no item wrapper). Codex emits several of these
      #     during a turn — intermediate progress messages followed by the
      #     final structured reply. Only the LAST one carries the full
      #     assistant text; earlier ones are partials or empty preambles.
      #   * `message`-with-content events — older codex shape
      #     `{item:{type:"message", content:[{text:"..."}]}}` builds the
      #     reply from concatenated content blocks across events. Kept as
      #     accumulation semantics for back-compat.
      #
      # When any `agent_message` event is seen, its last-wins text takes
      # precedence over any `message`-content accumulation. Mixed streams
      # therefore prefer the new shape's terminal event.
      def parse_output_codex(stdout_lines)
        legacy_text = String.new(encoding: Encoding::UTF_8)
        last_agent_message_text = nil
        in_tokens = 0
        out_tokens = 0
        stop_reason = nil
        unparsed = String.new(encoding: Encoding::UTF_8)

        stdout_lines.each do |raw|
          next if raw.strip.empty?

          parsed = (JSON.parse(raw) rescue nil)
          unless parsed.is_a?(Hash)
            unparsed << raw << "\n"
            next
          end

          if (agent_text = extract_codex_agent_message_text(parsed))
            last_agent_message_text = agent_text
          else
            collected = extract_text(parsed)
            legacy_text << collected if collected
          end

          if (u = parsed["usage"]).is_a?(Hash)
            in_tokens  += (u["input_tokens"]  || u["prompt_tokens"]    || 0).to_i
            out_tokens += (u["output_tokens"] || u["completion_tokens"] || 0).to_i
          end

          stop_reason = parsed["stop_reason"] || parsed["finish_reason"] || stop_reason
        end

        text = last_agent_message_text || legacy_text
        [text, { "input_tokens" => in_tokens, "output_tokens" => out_tokens }, stop_reason, unparsed]
      end

      # Codex agent_message text, in either the 0.129+ wrapped shape
      # (`{item:{type:"agent_message", text:"..."}}`) or the older flat
      # shape (`{type:"agent_message", text:"..."}`). Returns nil for any
      # other event so the legacy accumulator path can handle it.
      def extract_codex_agent_message_text(event)
        item = event["item"]
        if item.is_a?(Hash) && item["type"] == "agent_message" && item["text"].is_a?(String)
          return item["text"]
        end
        if event["type"] == "agent_message" && event["text"].is_a?(String)
          return event["text"]
        end
        nil
      end

      # Recognise text in the few JSONL event shapes both Codex and Claude
      # CLIs emit. Returns the text fragment to append, or nil.
      def extract_text(event)
        return event["text"] if event["text"].is_a?(String)

        if event["delta"].is_a?(Hash) && event["delta"]["text"].is_a?(String)
          return event["delta"]["text"]
        end

        item = event["item"]
        if item.is_a?(Hash) && item["type"] == "message"
          parts = Array(item["content"])
          return parts.filter_map { |p| p["text"] if p.is_a?(Hash) && p["text"].is_a?(String) }.join
        end

        msg = event["message"]
        if msg.is_a?(Hash)
          parts = Array(msg["content"])
          return parts.filter_map { |p| p["text"] if p.is_a?(Hash) && p["text"].is_a?(String) }.join unless parts.empty?
          return msg["content"] if msg["content"].is_a?(String)
        end

        nil
      end
    end
  end
end
