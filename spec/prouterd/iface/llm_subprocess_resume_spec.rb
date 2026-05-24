require "spec_helper"
require "json"

# Coverage for the resume-from session feature: parsers surface
# session_id, build_invocation / build_argv_claude inject the resume
# flags, and the canonical output hash carries session_id so a
# downstream block can read `{{block.session_id}}`.
RSpec.describe Prouterd::Iface::LlmSubprocess do
  describe ".parse_output_claude carries session_id" do
    it "extracts session_id from the wrapper JSON" do
      lines = [JSON.dump(
        "type" => "result", "subtype" => "success",
        "result" => "hello", "session_id" => "claude-sess-abc",
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
      )]
      text, _usage, _stop, _unparsed, session_id = described_class.parse_output_claude(lines)
      expect(text).to eq("hello")
      expect(session_id).to eq("claude-sess-abc")
    end

    it "returns nil session_id when the wrapper omits the field" do
      lines = [JSON.dump("type" => "result", "result" => "x", "usage" => {})]
      _, _, _, _, session_id = described_class.parse_output_claude(lines)
      expect(session_id).to be_nil
    end

    it "returns nil session_id when stdout was unparseable" do
      _, _, _, _, session_id = described_class.parse_output_claude(["{garbage"])
      expect(session_id).to be_nil
    end
  end

  describe ".parse_output_claude_stream carries session_id" do
    it "captures session_id from the first event that carries it" do
      lines = [
        JSON.dump("type" => "system", "session_id" => "stream-sess-1"),
        JSON.dump("type" => "assistant", "session_id" => "stream-sess-1"),
        JSON.dump("type" => "result", "session_id" => "stream-sess-1",
                  "result" => "done", "usage" => { "input_tokens" => 1, "output_tokens" => 1 })
      ]
      text, _, _, _, session_id = described_class.parse_output_claude_stream(lines)
      expect(text).to eq("done")
      expect(session_id).to eq("stream-sess-1")
    end
  end

  describe ".parse_output_codex carries session_id" do
    it "captures session_id from a session_configured event" do
      lines = [
        JSON.dump("type" => "session_configured", "session_id" => "codex-roll-xyz"),
        JSON.dump("type" => "item.completed", "item" => { "type" => "agent_message", "text" => "ok" })
      ]
      text, _, _, _, session_id = described_class.parse_output_codex(lines)
      expect(text).to eq("ok")
      expect(session_id).to eq("codex-roll-xyz")
    end

    it "accepts session_id nested under item.session_id (defensive)" do
      lines = [
        JSON.dump("type" => "item.started", "item" => { "session_id" => "wrapped-id" }),
        JSON.dump("type" => "item.completed", "item" => { "type" => "agent_message", "text" => "ok" })
      ]
      _, _, _, _, session_id = described_class.parse_output_codex(lines)
      expect(session_id).to eq("wrapped-id")
    end

    it "ignores empty-string session_id on either form" do
      lines = [
        JSON.dump("type" => "session_configured", "session_id" => ""),
        JSON.dump("type" => "item.started", "item" => { "session_id" => "" })
      ]
      _, _, _, _, session_id = described_class.parse_output_codex(lines)
      expect(session_id).to be_nil
    end

    it "keeps the first non-empty session_id (later events don't overwrite)" do
      lines = [
        JSON.dump("type" => "session_configured", "session_id" => "first-roll"),
        JSON.dump("type" => "session_configured", "session_id" => "second-roll")
      ]
      _, _, _, _, session_id = described_class.parse_output_codex(lines)
      expect(session_id).to eq("first-roll")
    end
  end

  describe ".build_partial_output preserves session_id" do
    it "carries session_id into the partial output hash" do
      out = described_class.build_partial_output(
        "partial", "m", { "input_tokens" => 0, "output_tokens" => 0 }, nil, "sess-1"
      )
      expect(out["session_id"]).to eq("sess-1")
    end

    it "still returns the partial hash when text is empty but session_id is set" do
      out = described_class.build_partial_output("", "m", {}, nil, "sess-1")
      expect(out).not_to be_nil
      expect(out["session_id"]).to eq("sess-1")
    end

    it "returns nil when text, usage, and session_id are all empty" do
      expect(described_class.build_partial_output("", "m", {}, nil, nil)).to be_nil
      expect(described_class.build_partial_output("", "m", {}, nil, "")).to be_nil
    end
  end

  describe ".build_argv_claude resume" do
    it "injects --resume <id> when resume_from is set" do
      argv = described_class.build_argv_claude(
        "/bin/claude", "claude-1", "prompt", nil, resume_from: "abc-123"
      )
      expect(argv).to include("--resume", "abc-123")
    end

    it "omits --resume when resume_from is nil or empty" do
      argv = described_class.build_argv_claude("/bin/claude", "m", "p", nil)
      expect(argv).not_to include("--resume")
      argv = described_class.build_argv_claude("/bin/claude", "m", "p", nil, resume_from: "")
      expect(argv).not_to include("--resume")
    end
  end

  describe ".build_invocation resume" do
    it "claude_cli: forwards resume_from into the argv" do
      argv, _ = described_class.build_invocation(
        "claude_cli", "/bin/claude", "claude-1", nil, "p", nil, resume_from: "claude-sess"
      )
      expect(argv).to include("--resume", "claude-sess")
    end

    it "codex_cli: rewrites argv to `exec resume <id> --json` when resume_from is set" do
      argv, _ = described_class.build_invocation(
        "codex_cli", "/bin/codex", "gpt-5", nil, "p", nil, resume_from: "codex-roll"
      )
      expect(argv[0, 5]).to eq(["/bin/codex", "exec", "resume", "codex-roll", "--json"])
    end

    it "codex_cli: keeps plain `exec --json` when resume_from is nil" do
      argv, _ = described_class.build_invocation(
        "codex_cli", "/bin/codex", "gpt-5", nil, "p", nil
      )
      expect(argv[0, 3]).to eq(["/bin/codex", "exec", "--json"])
    end

    it "codex_cli: strips whitespace-only resume_from" do
      argv, _ = described_class.build_invocation(
        "codex_cli", "/bin/codex", "gpt-5", nil, "p", nil, resume_from: "   "
      )
      expect(argv[0, 3]).to eq(["/bin/codex", "exec", "--json"])
    end
  end

  describe "LlmCaller passes resume-from through" do
    it "threads request.field('resume-from') into LlmSubprocess.call" do
      caller = Prouterd::Iface::LlmCaller.new
      req = double(
        timeout_ms: 1000,
        env: {}, log_sink: nil
      )
      fields = {
        "provider" => "claude_cli", "model" => "m", "prompt" => "hi",
        "system" => "", "max-tokens" => nil, "temperature" => nil,
        "binary" => "/usr/bin/true", "home" => nil, "sandbox" => nil,
        "cwd" => nil, "reasoning-effort" => nil,
        "env" => nil, "env-forward" => nil, "secret" => nil,
        "stream" => "off", "auth" => nil, "base-url" => nil,
        "resume-from" => "session-X"
      }
      allow(req).to receive(:field) { |k| fields[k] }

      captured = nil
      allow(Prouterd::Iface::LlmSubprocess).to receive(:call) do |**kwargs|
        captured = kwargs
        { exit_code: 0, output_json: {}, stdout: "", stderr: "",
          error_type: nil, error_message: nil }
      end
      caller.send(:perform_run, req)
      expect(captured[:resume_from]).to eq("session-X")
    end
  end
end
