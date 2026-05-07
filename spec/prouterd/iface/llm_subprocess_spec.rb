require "spec_helper"
require "tmpdir"
require "tempfile"

# Phase 37h: codex_cli / claude_cli LLM providers via subprocess.
RSpec.describe Prouterd::Iface::LlmSubprocess do
  # Build a temporary "binary" — a shell script that emits canned JSONL
  # to stdout and then exits 0 — and point the driver at it.
  def fake_binary(jsonl_lines, exit_code: 0)
    f = Tempfile.create(["fake-llm-", ".sh"])
    f.write("#!/bin/sh\n")
    jsonl_lines.each { |l| f.write("printf '%s\\n' #{shell_quote(l)}\n") }
    f.write("exit #{exit_code}\n")
    f.close
    File.chmod(0o755, f.path)
    f.path
  end

  def shell_quote(text)
    "'#{text.gsub("'", "'\\\\''")}'"
  end

  it "aggregates message text out of codex-style item.completed events" do
    bin = fake_binary([
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"hello"}]}}',
      '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":" world"}]}}',
      '{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3},"stop_reason":"end_turn"}'
    ])

    result = described_class.call(
      provider: "codex_cli",
      model:    "gpt-5-codex",
      binary:   bin,
      home:     nil,
      sandbox:  "read-only",
      prompt:   "ping",
      system_msg: "be brief",
      timeout_ms: 5_000
    )

    expect(result[:exit_code]).to eq(0)
    expect(result[:error_type]).to be_nil
    expect(result[:output_json]["text"]).to eq("hello world")
    expect(result[:output_json]["usage"]).to eq("input_tokens" => 12, "output_tokens" => 3)
    expect(result[:output_json]["stop_reason"]).to eq("end_turn")
    expect(result[:output_json]["model"]).to eq("gpt-5-codex")

    File.unlink(bin)
  end

  it "aggregates claude-style message_delta events" do
    bin = fake_binary([
      '{"type":"message_start"}',
      '{"type":"message_delta","delta":{"text":"abc"}}',
      '{"type":"message_delta","delta":{"text":"def"}}',
      '{"type":"message_stop","usage":{"input_tokens":7,"output_tokens":4}}'
    ])

    result = described_class.call(
      provider: "claude_cli",
      model:    "claude-haiku-4-5-20251001",
      binary:   bin,
      home:     nil,
      sandbox:  nil,
      prompt:   "ping",
      system_msg: "",
      timeout_ms: 5_000
    )

    expect(result[:output_json]["text"]).to eq("abcdef")
    expect(result[:output_json]["usage"]).to eq("input_tokens" => 7, "output_tokens" => 4)

    File.unlink(bin)
  end

  it "surfaces a missing-binary error when the path does not exist" do
    result = described_class.call(
      provider: "codex_cli",
      model:    "x",
      binary:   "/nonexistent/codex_xxx",
      home:     nil, sandbox: nil,
      prompt:   "ping", system_msg: "",
      timeout_ms: 1_000
    )
    expect(result[:error_type]).to eq("missing_dependency")
    expect(result[:error_message]).to include("not found")
  end

  it "surfaces a non-zero exit as llm_error" do
    bin = fake_binary(['{"type":"error","message":"oops"}'], exit_code: 7)

    result = described_class.call(
      provider: "codex_cli",
      model:    "x",
      binary:   bin,
      home:     nil, sandbox: nil,
      prompt:   "ping", system_msg: "",
      timeout_ms: 5_000
    )
    expect(result[:error_type]).to eq("llm_error")
    expect(result[:exit_code]).to eq(7)

    File.unlink(bin)
  end
end
