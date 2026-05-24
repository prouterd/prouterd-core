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

  # Real Claude Code CLI 2.1.x in `-p --output-format json` mode emits
  # ONE wrapper JSON object on stdout. Schema (per docs/headless):
  #   {type, subtype, is_error, result, session_id, usage,
  #    total_cost_usd, model}
  it "parses claude-style single-JSON-wrapper output" do
    wrapper = JSON.dump(
      "type"           => "result",
      "subtype"        => "success",
      "is_error"       => false,
      "result"         => "hello world",
      "session_id"     => "sess_abc",
      "usage"          => { "input_tokens" => 7, "output_tokens" => 4 },
      "total_cost_usd" => 0.0001,
      "model"          => "claude-haiku-4-5"
    )
    bin = fake_binary([wrapper])

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

    expect(result[:output_json]["text"]).to eq("hello world")
    expect(result[:output_json]["usage"]).to eq("input_tokens" => 7, "output_tokens" => 4)
    expect(result[:output_json]["stop_reason"]).to eq("success")

    File.unlink(bin)
  end

  it "builds the real Claude Code argv (-p / --output-format / --model / --system-prompt)" do
    captured = nil
    allow(Open3).to receive(:popen3).and_wrap_original do |original, *args, &blk|
      env = args.first.is_a?(Hash) ? args.shift : {}
      captured = args.dup
      original.call(env, *args, &blk)
    end
    bin = fake_binary([JSON.dump(
      "type" => "result", "subtype" => "success", "is_error" => false,
      "result" => "ok", "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )])

    described_class.call(
      provider: "claude_cli",
      model:    "claude-sonnet-4-6",
      binary:   bin,
      home:     nil, sandbox: nil,
      prompt:   "what is 2+2?",
      system_msg: "you are terse",
      timeout_ms: 5_000
    )

    expect(captured).to include(bin, "-p", "what is 2+2?", "--output-format", "json",
                                "--model", "claude-sonnet-4-6",
                                "--system-prompt", "you are terse")
    expect(captured).not_to include("--bare")
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

  # Codex 0.129+ wraps the assistant's final message as
  #   {type:"item.completed", item:{type:"agent_message", text:"..."}}
  # and emits several such events during a turn — intermediate progress
  # before the final structured reply. Driver picks the LAST one.
  it "picks the last codex agent_message text when several arrive" do
    bin = fake_binary([
      '{"type":"thread.started","thread_id":"t1"}',
      '{"type":"item.completed","item":{"type":"agent_message","text":""}}',
      '{"type":"item.completed","item":{"type":"agent_message","text":"thinking..."}}',
      '{"type":"item.completed","item":{"type":"agent_message","text":"final answer"}}',
      '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
    ])

    result = described_class.call(
      provider: "codex_cli", model: "gpt-5-codex",
      binary: bin, home: nil, sandbox: nil,
      prompt: "go", system_msg: "",
      timeout_ms: 5_000
    )

    expect(result[:exit_code]).to eq(0)
    expect(result[:output_json]["text"]).to eq("final answer")
    expect(result[:output_json]["usage"]).to eq("input_tokens" => 10, "output_tokens" => 5)

    File.unlink(bin)
  end

  # Older codex shape — flat `{type:"agent_message", text:"..."}` with no
  # `item` wrapper — still triggers last-wins, so a mid-turn empty preamble
  # doesn't shadow the final reply.
  it "applies last-wins to the flat agent_message shape too" do
    bin = fake_binary([
      '{"type":"agent_message","text":""}',
      '{"type":"agent_message","text":"final"}'
    ])

    result = described_class.call(
      provider: "codex_cli", model: "x",
      binary: bin, home: nil, sandbox: nil,
      prompt: "go", system_msg: "",
      timeout_ms: 5_000
    )

    expect(result[:output_json]["text"]).to eq("final")
    File.unlink(bin)
  end

  # When a stream mixes old `message`-with-content events and new
  # `agent_message` events, the agent_message last-wins text takes
  # precedence — the new shape is canonical when present.
  it "prefers agent_message text over legacy message-content accumulation" do
    bin = fake_binary([
      '{"type":"item.completed","item":{"type":"message","content":[{"type":"text","text":"old "}]}}',
      '{"type":"item.completed","item":{"type":"agent_message","text":"new answer"}}'
    ])

    result = described_class.call(
      provider: "codex_cli", model: "x",
      binary: bin, home: nil, sandbox: nil,
      prompt: "go", system_msg: "",
      timeout_ms: 5_000
    )

    expect(result[:output_json]["text"]).to eq("new answer")
    File.unlink(bin)
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
