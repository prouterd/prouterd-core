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

      def call(provider:, model:, binary:, home:, sandbox:, prompt:, system_msg:, timeout_ms:)
        argv = build_argv(provider, binary, model, sandbox)
        env = build_env(home)

        unless cli_available?(argv.first)
          return {
            exit_code: nil, output_json: nil, stdout: "", stderr: "",
            error_type: "missing_dependency",
            error_message: "#{provider} binary '#{argv.first}' not found on PATH (set `binary <path>` on the interface or PROUTERD_#{provider.upcase}_BIN env)"
          }
        end

        stdin_text = build_stdin(prompt, system_msg)
        stdout_lines, stderr_text, status = run_subprocess(env, argv, stdin_text, timeout_ms || DEFAULT_TIMEOUT_MS)

        if status == :timeout
          return { exit_code: nil, output_json: nil, stdout: "", stderr: stderr_text,
                   error_type: "timeout",
                   error_message: "#{provider} timed out after #{timeout_ms || DEFAULT_TIMEOUT_MS}ms" }
        end

        text, usage, stop_reason, raw_stderr_extra = aggregate(stdout_lines)
        stderr_combined = [stderr_text, raw_stderr_extra].reject(&:empty?).join

        if !status.success?
          return {
            exit_code:     status.exitstatus,
            output_json:   nil,
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

      def build_argv(provider, binary, model, sandbox)
        bin = binary
        bin = nil if bin.respond_to?(:empty?) && bin.empty?
        bin ||= ENV["PROUTERD_#{provider.upcase}_BIN"]
        bin ||= provider == "codex_cli" ? "codex" : "claude"

        argv = [bin, "exec", "--json"]
        argv += ["-m", model] unless model.empty?
        argv += ["-s", sandbox] if sandbox && !sandbox.empty?
        # `--skip-git-repo-check` is benign on both binaries when present
        # (codex requires it for non-repo dirs; claude ignores unknown
        # flags) — leave it off to keep the argv minimal.
        argv
      end

      def build_env(home)
        env = {}
        env["HOME"] = home if home && !home.empty?
        env
      end

      def build_stdin(prompt, system_msg)
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

      def run_subprocess(env, argv, stdin_text, timeout_ms)
        stdout_lines = []
        stderr_buf = String.new(encoding: Encoding::UTF_8)
        status = nil

        deadline = Time.now + (timeout_ms / 1000.0)
        Open3.popen3(env, *argv) do |stdin, stdout, stderr, wait_thr|
          stdin.write(stdin_text) rescue nil
          stdin.close rescue nil

          out_thread = Thread.new { stdout.each_line { |l| stdout_lines << l.chomp } }
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

      def aggregate(stdout_lines)
        text = String.new(encoding: Encoding::UTF_8)
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

          collected = extract_text(parsed)
          text << collected if collected

          if (u = parsed["usage"]).is_a?(Hash)
            in_tokens  += (u["input_tokens"]  || u["prompt_tokens"]    || 0).to_i
            out_tokens += (u["output_tokens"] || u["completion_tokens"] || 0).to_i
          end

          stop_reason = parsed["stop_reason"] || parsed["finish_reason"] || stop_reason
        end

        [text, { "input_tokens" => in_tokens, "output_tokens" => out_tokens }, stop_reason, unparsed]
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
