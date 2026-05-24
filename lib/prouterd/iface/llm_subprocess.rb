# frozen_string_literal: true

require "open3"
require "json"
require_relative "llm_subprocess/session"

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
               stream: false, stream_sink: nil, resume_from: nil)
        argv, stdin_text = build_invocation(provider, binary, model, sandbox, prompt, system_msg,
                                             reasoning_effort: reasoning_effort,
                                             stream: stream,
                                             resume_from: resume_from)
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

        session = Session.new(env: env, argv: argv, timeout_ms: timeout_ms,
                              cwd: resolved_cwd, sandbox_env: sandbox_env)
        result = session.run do |stdin, stdout, _handle|
          stdin.write(stdin_text) rescue nil
          stdin.close rescue nil
          collect_stdout_lines(stdout, stream_sink)
        end
        stdout_lines = result.value
        stderr_text  = result.stderr_text
        status       = result.status

        if status == :timeout
          return { exit_code: nil, output_json: nil, stdout: "", stderr: stderr_text,
                   error_type: "timeout",
                   error_message: "#{provider} timed out after #{timeout_ms || DEFAULT_TIMEOUT_MS}ms" }
        end

        # Output protocol differs by provider — codex emits JSONL events,
        # claude (-p mode) emits one wrapper JSON object on stdout (or
        # JSONL when `--output-format stream-json` is active).
        text, usage, stop_reason, raw_stderr_extra, session_id =
          parse_output(provider, stdout_lines, stream: stream)
        stderr_combined = [stderr_text, raw_stderr_extra].reject(&:empty?).join

        if !status.success?
          # Preserve any text / usage the model emitted before the
          # subprocess died. Codex/Claude can hit a contract violation
          # or rate limit mid-turn and still have streamed partial
          # output; the operator wants to see it on the failed step
          # row. Downstream context propagation is gated on success in
          # BlockExecutor, so this only affects persistence.
          partial = build_partial_output(text, model, usage, stop_reason, session_id)
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
            "stop_reason" => stop_reason,
            "session_id"  => session_id
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
                           reasoning_effort: nil, stream: false, resume_from: nil)
        bin = resolve_binary(provider, binary)
        resume = resume_from.to_s.strip
        resume = nil if resume.empty?
        case provider
        when "codex_cli"
          # Codex CLI emits JSONL events under `--json` regardless of
          # whether the operator opted into streaming on the prouterd
          # side — the `stream:` flag here just controls whether the
          # driver tees each line into the per-step log table as it
          # arrives, not the codex invocation itself.
          #
          # When `resume_from` is set, codex re-opens the prior rollout
          # via `codex exec resume <id> --json` so the next prompt
          # continues that conversation; otherwise a fresh rollout
          # starts via plain `codex exec --json`.
          argv = if resume
                   [bin, "exec", "resume", resume, "--json"]
                 else
                   [bin, "exec", "--json"]
                 end
          argv += ["-m", model] unless model.to_s.empty?
          argv += ["-s", sandbox] if sandbox && !sandbox.empty?
          argv += codex_reasoning_args(reasoning_effort)
          stdin_text = build_codex_stdin(prompt, system_msg)
        when "claude_cli"
          # reasoning_effort is a codex-only concept; silently ignored
          # for Claude Code (it has its own thinking-mode toggles via
          # a different API).
          argv = build_argv_claude(bin, model, prompt, system_msg, stream: stream, resume_from: resume)
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
      #          [--resume <session_id>]
      #
      # `--system-prompt` FULLY replaces Claude Code's default agent
      # system prompt; that's what we want for `interface llm` blocks
      # (no Claude-Code-agent baggage). Without `system_msg` we omit
      # the flag and let Claude Code apply its default — usually fine
      # for one-shot prompts.
      #
      # `--resume <id>` re-opens the prior session so the next prompt
      # is appended to that conversation rather than starting fresh.
      def build_argv_claude(bin, model, prompt, system_msg, stream: false, resume_from: nil)
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
        argv += ["--resume", resume_from] if resume_from && !resume_from.to_s.empty?
        argv
      end

      def resolve_binary(provider, binary)
        bin = binary
        bin = nil if bin.respond_to?(:empty?) && bin.empty?
        bin ||= ENV["PROUTERD_#{provider.upcase}_BIN"]
        bin ||= provider == "codex_cli" ? "codex" : "claude"
        bin
      end

      # Shared `env` / `env-forward` / `secret` resolver for subprocess
      # LLM spawns. Returns `[extra_env, sandbox_env]` where
      # `sandbox_env` is true when ANY of the three is declared on the
      # interface — the opt-in signal that the spawn should run with
      # `unsetenv_others: true` so a prompt-injection can't exfiltrate
      # whatever else the daemon was started with.
      #
      # Resolution rules:
      #   env_static  Hash<KEY, VALUE>  — static (already templated)
      #   env_forward Array<KEY>        — pass through ENV[KEY] if set
      #   secret_refs Array<NAME>       — read resolved value from
      #                                    parent_env[NAME] (the
      #                                    orchestrator's resolver
      #                                    populated it already)
      def build_subprocess_env(env_static:, env_forward:, secret_refs:, parent_env:)
        env_static  = env_static.is_a?(Hash) ? env_static : {}
        env_forward = Array(env_forward)
        secret_refs = Array(secret_refs)
        sandbox_env = !env_static.empty? || !env_forward.empty? || !secret_refs.empty?

        extra = {}
        env_static.each { |k, v| extra[k.to_s] = v.to_s }
        env_forward.each do |key|
          v = ENV[key]
          extra[key] = v.to_s if v
        end
        secret_refs.each do |name|
          v = (parent_env || {})[name]
          extra[name] = v.to_s if v
        end

        [extra, sandbox_env]
      end

      def build_env(home)
        env = {}
        env["HOME"] = home if home && !home.empty?
        # Default the spawn's locale to a UTF-8-capable one. Without
        # this, a daemon started without `LANG` / `LC_ALL` in its env
        # (typical on macOS launchd, minimal Docker images) leaves the
        # child CLI in the C locale, where it falls back to ASCII
        # output — every non-ASCII byte in the model's response then
        # becomes an escape sequence the JSONL parser doesn't expect.
        # The operator can override either var via `env KEY VALUE` /
        # `env-forward KEY` (those merge on top of this hash).
        env["LANG"]   = "C.UTF-8"
        env["LC_ALL"] = "C.UTF-8"
        env
      end

      def build_codex_stdin(prompt, system_msg)
        if system_msg && !system_msg.empty?
          "[SYSTEM]\n#{system_msg}\n[USER]\n#{prompt}\n"
        else
          "#{prompt}\n"
        end
      end

      # Force-tag an arbitrary string as UTF-8, replacing invalid byte
      # sequences with `?`. Idempotent for already-valid UTF-8.
      # Centralised so `LlmAgentic` can share the same fix.
      def utf8_safe(str)
        s = str.to_s
        s = s.dup if s.frozen?
        s.force_encoding(Encoding::UTF_8)
        s.valid_encoding? ? s : s.scrub("?")
      end

      def cli_available?(bin)
        return true if bin.start_with?("/") && File.executable?(bin)

        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, bin))
        end
      end

      # Drain a subprocess stdout pipe into an array, force-tagging
      # UTF-8 + scrubbing invalid sequences per line. When the operator
      # opted into streaming, each line is also handed to the per-step
      # log sink as it arrives so `prouter logs <run_uid> --follow`
      # sees agent progress without waiting for the subprocess to
      # terminate. The Session watchdog kills the spawn on deadline
      # expiry; the pipe then EOFs and `each_line` returns naturally.
      def collect_stdout_lines(stdout, stream_sink)
        lines = []
        stdout.each_line do |raw|
          line = utf8_safe(raw).chomp
          lines << line
          stream_sink&.call(line, "stdout")
        end
        lines
      end

      # Build the canonical output shape from parsed pieces, or return
      # nil if the subprocess produced no text and zero token usage.
      # Used on the failure path so a step row only carries a partial
      # output_json when the model actually streamed something — empty
      # failures stay output_json=nil. When the subprocess emitted a
      # `session_id` before dying we still surface it so a downstream
      # block can resume the conversation on retry.
      def build_partial_output(text, model, usage, stop_reason, session_id = nil)
        text_str = text.to_s
        in_tokens  = (usage["input_tokens"]  if usage.is_a?(Hash)).to_i
        out_tokens = (usage["output_tokens"] if usage.is_a?(Hash)).to_i
        return nil if text_str.empty? && in_tokens.zero? && out_tokens.zero? && session_id.to_s.empty?

        {
          "text"        => text_str,
          "model"       => model,
          "usage"       => usage,
          "stop_reason" => stop_reason,
          "session_id"  => session_id
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
          return ["", { "input_tokens" => 0, "output_tokens" => 0 }, nil, unparsed, nil]
        end

        text = parsed["result"].to_s
        text = parsed["structured_output"].to_json if parsed["structured_output"]
        usage = parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}
        in_tokens  = (usage["input_tokens"]  || usage["prompt_tokens"]    || 0).to_i
        out_tokens = (usage["output_tokens"] || usage["completion_tokens"] || 0).to_i
        stop_reason = parsed["stop_reason"] || parsed["subtype"]
        session_id = parsed["session_id"]

        [text, { "input_tokens" => in_tokens, "output_tokens" => out_tokens }, stop_reason, unparsed, session_id]
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
        session_id = nil

        stdout_lines.each do |raw|
          next if raw.strip.empty?
          event = (JSON.parse(raw) rescue nil)
          unless event.is_a?(Hash)
            unparsed << raw << "\n"
            next
          end

          # `session_id` appears on every event Claude Code emits in
          # stream-json mode (init, assistant, result). Capture the
          # first one we see — they all refer to the same session.
          session_id ||= event["session_id"]

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

        [text, usage, stop_reason, unparsed, session_id]
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
        session_id = nil
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

          # Codex emits its rollout id on the `session_configured`
          # event early in the JSONL stream:
          #   {type:"session_configured", session_id:"..."}
          # Subsequent events may also carry it; first non-nil wins.
          session_id ||= extract_codex_session_id(parsed)

          stop_reason = parsed["stop_reason"] || parsed["finish_reason"] || stop_reason
        end

        text = last_agent_message_text || legacy_text
        [text, { "input_tokens" => in_tokens, "output_tokens" => out_tokens }, stop_reason, unparsed, session_id]
      end

      # Codex session id. Top-level `session_id` on `session_configured`
      # events (codex 0.129+) and on item events that include it. Also
      # accepts a wrapped form `{item:{session_id:"..."}}` defensively
      # — codex versions vary on whether the field is hoisted.
      def extract_codex_session_id(event)
        sid = event["session_id"]
        return sid if sid.is_a?(String) && !sid.empty?

        item = event["item"]
        if item.is_a?(Hash)
          sid = item["session_id"]
          return sid if sid.is_a?(String) && !sid.empty?
        end
        nil
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
          # `Array("x")` is `["x"]`, not empty — so a String `content`
          # falls into the filter_map branch above and produces "".
          # No separate String-fallback branch is reachable.
          return parts.filter_map { |p| p["text"] if p.is_a?(Hash) && p["text"].is_a?(String) }.join unless parts.empty?
        end

        nil
      end
    end
  end
end
