require "spec_helper"
require "tmpdir"
require "tempfile"

# Coverage-extension specs for Prouterd::Iface::LlmSubprocess. Targets
# the branches not exercised by llm_subprocess_spec.rb — small helper
# methods and pure parsers.
RSpec.describe Prouterd::Iface::LlmSubprocess do
  describe ".build_invocation" do
    it "builds codex_cli argv without -m when model is empty and without -s when sandbox is empty" do
      argv, stdin_text = described_class.build_invocation("codex_cli", "/bin/echo", "", "", "ping", "")
      expect(argv).to eq(["/bin/echo", "exec", "--json"])
      expect(stdin_text).to eq("ping\n")
    end

    it "builds codex_cli argv with -s when sandbox is set, and embeds system_msg in stdin" do
      argv, stdin_text = described_class.build_invocation(
        "codex_cli", "/bin/echo", "gpt-5", "read-only", "u", "sys",
        reasoning_effort: "low"
      )
      expect(argv).to eq(["/bin/echo", "exec", "--json", "-m", "gpt-5",
                          "-s", "read-only", "-c", "model_reasoning_effort=low"])
      expect(stdin_text).to start_with("[SYSTEM]\nsys\n[USER]\nu\n")
    end

    it "builds claude_cli argv with stream-json + verbose when stream: true and empty stdin" do
      argv, stdin_text = described_class.build_invocation(
        "claude_cli", "/bin/echo", "m", nil, "p", "sys", stream: true
      )
      expect(argv).to include("--output-format", "stream-json", "--verbose",
                              "--model", "m", "--system-prompt", "sys")
      expect(stdin_text).to eq("")
    end

    it "builds claude_cli argv without --verbose for non-stream and skips --model when model empty" do
      argv, _stdin = described_class.build_invocation(
        "claude_cli", "/bin/echo", "", nil, "p", "", stream: false
      )
      expect(argv).to include("--output-format", "json")
      expect(argv).not_to include("--verbose")
      expect(argv).not_to include("--model")
      expect(argv).not_to include("--system-prompt")
    end

    it "raises ArgumentError for an unknown provider" do
      expect {
        described_class.build_invocation("ghost_cli", "/bin/echo", "m", nil, "p", "")
      }.to raise_error(ArgumentError, /unknown subprocess provider/)
    end
  end

  describe ".build_argv" do
    it "raises ArgumentError for non-codex_cli providers" do
      expect {
        described_class.build_argv("claude_cli", "/bin/echo", "m", nil)
      }.to raise_error(ArgumentError, /build_argv only supports codex_cli/)
    end

    it "builds the codex_cli argv with model + sandbox + reasoning" do
      argv = described_class.build_argv("codex_cli", "/bin/echo", "m", "read-only",
                                        reasoning_effort: "high")
      expect(argv).to eq(["/bin/echo", "exec", "--json", "-m", "m", "-s", "read-only",
                          "-c", "model_reasoning_effort=high"])
    end

    it "omits -m/-s/reasoning args when their inputs are empty/nil" do
      argv = described_class.build_argv("codex_cli", "/bin/echo", "", nil)
      expect(argv).to eq(["/bin/echo", "exec", "--json"])
    end
  end

  describe ".build_argv_claude" do
    it "adds --verbose when stream: true (stream-json mode requires it)" do
      argv = described_class.build_argv_claude("/bin/echo", "m", "p", "sys", stream: true)
      expect(argv).to include("--output-format", "stream-json", "--verbose")
    end

    it "omits --model when model is empty and --system-prompt when system_msg is empty" do
      argv = described_class.build_argv_claude("/bin/echo", "", "p", nil)
      expect(argv).not_to include("--model")
      expect(argv).not_to include("--system-prompt")
    end
  end

  describe ".resolve_binary" do
    around do |ex|
      original = ENV["PROUTERD_CODEX_CLI_BIN"]
      original_claude = ENV["PROUTERD_CLAUDE_CLI_BIN"]
      ex.run
      ENV["PROUTERD_CODEX_CLI_BIN"] = original
      ENV["PROUTERD_CLAUDE_CLI_BIN"] = original_claude
    end

    it "returns the explicit binary when non-empty" do
      expect(described_class.resolve_binary("codex_cli", "/explicit/codex")).to eq("/explicit/codex")
    end

    it "honours PROUTERD_<PROVIDER>_BIN when binary is empty" do
      ENV["PROUTERD_CODEX_CLI_BIN"] = "/env/codex"
      expect(described_class.resolve_binary("codex_cli", "")).to eq("/env/codex")
    end

    it "falls back to 'codex' for codex_cli and 'claude' for claude_cli when nothing else is set" do
      ENV["PROUTERD_CODEX_CLI_BIN"] = nil
      ENV["PROUTERD_CLAUDE_CLI_BIN"] = nil
      expect(described_class.resolve_binary("codex_cli", nil)).to eq("codex")
      expect(described_class.resolve_binary("claude_cli", nil)).to eq("claude")
    end
  end

  describe ".resolve_cwd" do
    it "returns nil for nil and empty string" do
      expect(described_class.resolve_cwd(nil)).to be_nil
      expect(described_class.resolve_cwd("")).to be_nil
    end

    it "returns the directory when it exists" do
      Dir.mktmpdir do |d|
        expect(described_class.resolve_cwd(d)).to eq(d)
      end
    end

    it "returns nil when the path is not a directory" do
      expect(described_class.resolve_cwd("/no/such/dir/here-xyz")).to be_nil
    end
  end

  describe ".codex_reasoning_args" do
    it "returns [] for nil / empty levels" do
      expect(described_class.codex_reasoning_args(nil)).to eq([])
      expect(described_class.codex_reasoning_args("")).to eq([])
    end

    it "returns the -c flag for a valid level" do
      expect(described_class.codex_reasoning_args("high")).to eq(["-c", "model_reasoning_effort=high"])
    end
  end

  describe ".cli_available?" do
    it "is true for an absolute path that exists + is executable" do
      f = Tempfile.create(["fake-bin-", ".sh"])
      f.write("#!/bin/sh\nexit 0\n")
      f.close
      File.chmod(0o755, f.path)
      begin
        expect(described_class.cli_available?(f.path)).to be true
      ensure
        File.unlink(f.path)
      end
    end

    it "is true for a bare name that lives on PATH" do
      # `sh` is in essentially every POSIX env we run tests on.
      expect(described_class.cli_available?("sh")).to be true
    end

    it "is false for a missing bare name" do
      expect(described_class.cli_available?("definitely_not_a_command_xyzzy")).to be false
    end
  end

  describe ".parse_output_claude" do
    it "extracts text + usage + stop_reason from the canonical wrapper" do
      lines = [JSON.dump(
        "type" => "result", "subtype" => "success",
        "result" => "hello", "usage" => { "input_tokens" => 3, "output_tokens" => 2 }
      )]
      text, usage, stop_reason, unparsed = described_class.parse_output_claude(lines)
      expect(text).to eq("hello")
      expect(usage).to eq("input_tokens" => 3, "output_tokens" => 2)
      expect(stop_reason).to eq("success")
      expect(unparsed).to eq("")
    end

    it "captures malformed JSON into the unparsed buffer with zero usage" do
      text, usage, stop_reason, unparsed = described_class.parse_output_claude(["{not-json"])
      expect(text).to eq("")
      expect(usage).to eq("input_tokens" => 0, "output_tokens" => 0)
      expect(stop_reason).to be_nil
      expect(unparsed).to include("{not-json")
    end

    it "prefers structured_output over result when present" do
      payload = { "type" => "result", "structured_output" => { "score" => 7 },
                  "result" => "ignored", "usage" => {} }
      text, _, _, _ = described_class.parse_output_claude([JSON.dump(payload)])
      parsed = JSON.parse(text)
      expect(parsed).to eq("score" => 7)
    end

    it "falls back to prompt_tokens / completion_tokens when input_tokens is missing" do
      payload = { "type" => "result", "result" => "ok",
                  "usage" => { "prompt_tokens" => 11, "completion_tokens" => 9 } }
      _, usage, _, _ = described_class.parse_output_claude([JSON.dump(payload)])
      expect(usage).to eq("input_tokens" => 11, "output_tokens" => 9)
    end
  end

  describe ".parse_output_codex" do
    it "returns last-wins agent_message text (wrapped shape)" do
      lines = [
        '{"type":"item.completed","item":{"type":"agent_message","text":"first"}}',
        '{"type":"item.completed","item":{"type":"agent_message","text":"final"}}'
      ]
      text, _, _, _ = described_class.parse_output_codex(lines)
      expect(text).to eq("final")
    end

    it "returns last-wins agent_message text (flat shape)" do
      lines = [
        '{"type":"agent_message","text":"x"}',
        '{"type":"agent_message","text":"y"}'
      ]
      text, _, _, _ = described_class.parse_output_codex(lines)
      expect(text).to eq("y")
    end

    it "accumulates content-text events when no agent_message ever arrives" do
      lines = [
        '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"one "}]}}',
        '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"two"}]}}'
      ]
      text, _, _, _ = described_class.parse_output_codex(lines)
      expect(text).to eq("one two")
    end

    it "accumulates usage across multiple events and captures non-JSON in unparsed" do
      lines = [
        "garbage line",
        '{"usage":{"input_tokens":3,"output_tokens":1}}',
        '{"usage":{"input_tokens":2,"output_tokens":4},"finish_reason":"end_turn"}',
        '   '
      ]
      _, usage, stop_reason, unparsed = described_class.parse_output_codex(lines)
      expect(usage).to eq("input_tokens" => 5, "output_tokens" => 5)
      expect(stop_reason).to eq("end_turn")
      expect(unparsed).to include("garbage line")
    end

    it "falls back to prompt_tokens / completion_tokens when codex emits the alt usage shape" do
      lines = ['{"usage":{"prompt_tokens":2,"completion_tokens":3}}']
      _, usage, _, _ = described_class.parse_output_codex(lines)
      expect(usage).to eq("input_tokens" => 2, "output_tokens" => 3)
    end
  end

  describe ".parse_output_claude_stream" do
    it "captures result text + usage from a result event" do
      lines = [
        JSON.dump("type" => "system", "subtype" => "init"),
        JSON.dump("type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "partial " }] }),
        JSON.dump("type" => "result", "subtype" => "success",
                  "result" => "final stream", "model" => "claude-x",
                  "usage" => { "input_tokens" => 4, "output_tokens" => 6 })
      ]
      text, usage, stop_reason, unparsed = described_class.parse_output_claude_stream(lines)
      expect(text).to eq("final stream")
      expect(usage).to eq("input_tokens" => 4, "output_tokens" => 6)
      expect(stop_reason).to eq("success")
      expect(unparsed).to eq("")
    end

    it "leaves text empty when no result event appears, and tracks unparsed lines" do
      lines = ["not-json", JSON.dump("type" => "system"), "   "]
      text, usage, stop_reason, unparsed = described_class.parse_output_claude_stream(lines)
      expect(text).to eq("")
      expect(usage).to eq("input_tokens" => 0, "output_tokens" => 0)
      expect(stop_reason).to be_nil
      expect(unparsed).to include("not-json")
    end

    it "prefers structured_output when the result event carries one" do
      lines = [JSON.dump("type" => "result", "structured_output" => { "a" => 1 },
                         "result" => "ignored",
                         "usage" => { "prompt_tokens" => 7, "completion_tokens" => 2 })]
      text, usage, _, _ = described_class.parse_output_claude_stream(lines)
      expect(JSON.parse(text)).to eq("a" => 1)
      expect(usage).to eq("input_tokens" => 7, "output_tokens" => 2)
    end
  end

  describe ".build_partial_output" do
    it "returns nil when text is empty and usage is zero" do
      expect(described_class.build_partial_output("", "m", {}, nil)).to be_nil
    end

    it "returns the canonical hash when text or usage is non-empty" do
      out = described_class.build_partial_output("some text", "m",
                                                  { "input_tokens" => 1, "output_tokens" => 0 }, "end")
      expect(out).to eq("text" => "some text", "model" => "m",
                        "usage" => { "input_tokens" => 1, "output_tokens" => 0 }, "stop_reason" => "end",
                        "session_id" => nil)
    end

    it "treats non-Hash usage as zero counts" do
      expect(described_class.build_partial_output("", "m", nil, nil)).to be_nil
    end

    it "returns the hash when only output_tokens is populated" do
      out = described_class.build_partial_output("", "m",
                                                  { "input_tokens" => 0, "output_tokens" => 4 }, nil)
      expect(out).not_to be_nil
      expect(out["usage"]).to eq("input_tokens" => 0, "output_tokens" => 4)
    end
  end

  describe ".build_subprocess_env" do
    it "returns extra={} and sandbox_env=false when all three sources are empty" do
      extra, sandbox = described_class.build_subprocess_env(
        env_static: nil, env_forward: nil, secret_refs: nil, parent_env: {}
      )
      expect(extra).to eq({})
      expect(sandbox).to be false
    end

    it "flips sandbox on when env_static is non-empty" do
      extra, sandbox = described_class.build_subprocess_env(
        env_static: { "A" => 1 }, env_forward: [], secret_refs: [], parent_env: {}
      )
      expect(extra).to eq("A" => "1")
      expect(sandbox).to be true
    end

    it "looks up env_forward keys in the host ENV" do
      ENV["PROUTERD_TEST_FORWARD"] = "yes"
      extra, sandbox = described_class.build_subprocess_env(
        env_static: {}, env_forward: ["PROUTERD_TEST_FORWARD"], secret_refs: [], parent_env: nil
      )
      expect(extra).to eq("PROUTERD_TEST_FORWARD" => "yes")
      expect(sandbox).to be true
    ensure
      ENV.delete("PROUTERD_TEST_FORWARD")
    end

    it "skips env_forward keys absent from host ENV" do
      ENV.delete("PROUTERD_TEST_MISSING_FORWARD_VAR")
      extra, sandbox = described_class.build_subprocess_env(
        env_static: {}, env_forward: ["PROUTERD_TEST_MISSING_FORWARD_VAR"],
        secret_refs: [], parent_env: nil
      )
      expect(extra).to eq({})
      expect(sandbox).to be true
    end

    it "reads secret_refs from parent_env when present and skips missing ones" do
      extra, sandbox = described_class.build_subprocess_env(
        env_static: {}, env_forward: [],
        secret_refs: ["KEY_A", "KEY_MISSING"],
        parent_env: { "KEY_A" => "val" }
      )
      expect(extra).to eq("KEY_A" => "val")
      expect(sandbox).to be true
    end

    it "treats a nil parent_env as empty for secret lookups" do
      extra, sandbox = described_class.build_subprocess_env(
        env_static: {}, env_forward: [], secret_refs: ["KEY_X"], parent_env: nil
      )
      expect(extra).to eq({})
      expect(sandbox).to be true
    end
  end

  describe ".utf8_safe" do
    it "dups a frozen string and returns UTF-8" do
      s = "ok".freeze
      out = described_class.utf8_safe(s)
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out).to eq("ok")
    end

    it "passes through valid UTF-8 unchanged" do
      out = described_class.utf8_safe("héllo")
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out).to eq("héllo")
    end

    it "force-tags ASCII-8BIT strings as UTF-8" do
      raw = "abc".dup.force_encoding(Encoding::ASCII_8BIT)
      out = described_class.utf8_safe(raw)
      expect(out.encoding).to eq(Encoding::UTF_8)
    end

    it "scrubs invalid byte sequences with ?" do
      bad = "ok-\xC3-bad".dup.force_encoding(Encoding::ASCII_8BIT)
      out = described_class.utf8_safe(bad)
      expect(out).to be_valid_encoding
      expect(out).to include("?")
    end
  end

  describe ".popen_options" do
    it "returns an empty hash when neither cwd nor sandbox_env is set" do
      expect(described_class.popen_options).to eq({})
    end

    it "returns {chdir: cwd} when only cwd is set" do
      expect(described_class.popen_options(cwd: "/tmp")).to eq(chdir: "/tmp")
    end

    it "returns {unsetenv_others: true} when only sandbox_env is true" do
      expect(described_class.popen_options(sandbox_env: true)).to eq(unsetenv_others: true)
    end

    it "merges both when both are set" do
      opts = described_class.popen_options(cwd: "/tmp", sandbox_env: true)
      expect(opts).to eq(chdir: "/tmp", unsetenv_others: true)
    end
  end

  describe ".parse_output dispatch" do
    it "routes claude_cli + stream: true to parse_output_claude_stream" do
      lines = [JSON.dump("type" => "result", "result" => "x",
                         "usage" => { "input_tokens" => 1, "output_tokens" => 1 })]
      text, _, _, _ = described_class.parse_output("claude_cli", lines, stream: true)
      expect(text).to eq("x")
    end

    it "routes anything else through the codex parser" do
      text, _, _, _ = described_class.parse_output("codex_cli",
        ['{"type":"agent_message","text":"hi"}'])
      expect(text).to eq("hi")
    end
  end

  describe ".extract_text edge cases" do
    it "returns the top-level text key when present" do
      expect(described_class.extract_text("text" => "hi")).to eq("hi")
    end

    it "returns nil when nothing recognised" do
      expect(described_class.extract_text({ "type" => "unknown" })).to be_nil
    end

    it "extracts delta.text shape" do
      expect(described_class.extract_text({ "delta" => { "text" => "x" } })).to eq("x")
    end

    it "joins message content parts (Array form)" do
      event = { "message" => { "content" => [{ "text" => "a" }, { "text" => "b" }, { "no" => 1 }] } }
      expect(described_class.extract_text(event)).to eq("ab")
    end

    it "falls back to message.content as string when parts is empty" do
      event = { "message" => { "content" => "" } }
      # Array("") → [""], not empty; filter_map → ""; join → "". This
      # confirms the string-fallback path is reachable only via the
      # explicit-empty parts branch (which produces "").
      expect(described_class.extract_text(event)).to eq("")
    end
  end

  describe ".extract_codex_agent_message_text" do
    it "returns nil for unrelated events" do
      expect(described_class.extract_codex_agent_message_text({ "type" => "other" })).to be_nil
    end

    it "returns nil when item is present but not agent_message" do
      expect(described_class.extract_codex_agent_message_text(
        "item" => { "type" => "message", "text" => "ignore" }
      )).to be_nil
    end
  end

  describe ".extract_text item.message branch with non-Hash content parts" do
    it "skips non-Hash content parts cleanly" do
      ev = { "item" => { "type" => "message", "content" => ["string-part", { "text" => "x" }] } }
      expect(described_class.extract_text(ev)).to eq("x")
    end

    it "returns nil when message.content is missing entirely" do
      expect(described_class.extract_text("message" => {})).to be_nil
    end
  end

  describe "claude wrapper edge branches" do
    it "parse_output_claude returns zero+nil for an empty stdout (joined empty)" do
      text, usage, stop_reason, unparsed = described_class.parse_output_claude([])
      expect(text).to eq("")
      expect(usage).to eq("input_tokens" => 0, "output_tokens" => 0)
      expect(stop_reason).to be_nil
      expect(unparsed).to eq("")
    end

    it "parse_output_claude treats non-Hash usage as empty" do
      payload = { "type" => "result", "result" => "ok", "usage" => "not a hash" }
      _, usage, _, _ = described_class.parse_output_claude([JSON.dump(payload)])
      expect(usage).to eq("input_tokens" => 0, "output_tokens" => 0)
    end
  end

  describe "claude_cli stream edge branches" do
    it "ignores a result event lacking the result key (still captures usage)" do
      lines = [JSON.dump("type" => "result", "usage" => { "input_tokens" => 9, "output_tokens" => 8 })]
      text, usage, _, _ = described_class.parse_output_claude_stream(lines)
      expect(text).to eq("")
      expect(usage).to eq("input_tokens" => 9, "output_tokens" => 8)
    end

    it "ignores a result event with no usage key" do
      lines = [JSON.dump("type" => "result", "result" => "hello")]
      text, usage, _, _ = described_class.parse_output_claude_stream(lines)
      expect(text).to eq("hello")
      expect(usage).to eq("input_tokens" => 0, "output_tokens" => 0)
    end
  end

  describe "LlmSubprocess.call timeout path" do
    it "returns error_type=timeout when the watchdog kills a hung child" do
      hang = Tempfile.create(["llm-hang-", ".sh"])
      # Hold stdout open, never write. Watchdog kills on the deadline.
      # `exec` so KILL hits sleep directly — without it the shell exits but
      # the orphaned sleep keeps stdout open, stretching the test to 10s.
      hang.write("#!/bin/sh\nexec sleep 10\n")
      hang.close
      File.chmod(0o755, hang.path)
      begin
        result = described_class.call(
          provider: "codex_cli", model: "x",
          binary: hang.path, home: nil, sandbox: nil,
          prompt: "p", system_msg: "",
          timeout_ms: 150
        )
        expect(result[:error_type]).to eq("timeout")
        expect(result[:error_message]).to include("timed out")
      ensure
        File.unlink(hang.path)
      end
    end
  end
end
