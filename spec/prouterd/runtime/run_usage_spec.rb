require "spec_helper"

# Phase 37f: per-run token usage accumulator.
RSpec.describe "per-run token usage accumulator" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_USAGE = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_USAGE + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img1
       exit
       route a b
      exit
    PRC
  end

  it "sums {input_tokens, output_tokens} across all attempts" do
    runner.program("a") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "text" => "x", "usage" => { "input_tokens" => 100, "output_tokens" => 50 } },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    runner.program("b") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "text" => "y", "usage" => { "input_tokens" => 25, "output_tokens" => 10 } },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    fetched = repo.get_run_by_uid(run.uid)
    expect(fetched.tokens_in).to eq(125)
    expect(fetched.tokens_out).to eq(60)
  end

  it "accumulates cost_usd against a `prices` table when iface declares the provider+model" do
    cost_doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      prices anthropic
       model claude-haiku-4-5-20251001 in 0.25 out 1.25
      exit
      interface llm chat
       provider anthropic
       model claude-haiku-4-5-20251001
      exit
      process p
       block ask
        interface llm chat
        prompt "ping"
       exit
      exit
    PRC
    runner.program("ask") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: {
          "text" => "x",
          "model" => "claude-haiku-4-5-20251001",
          "usage" => { "input_tokens" => 1_000_000, "output_tokens" => 500_000 }
        },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    # Wire HTTP layer for the LLM block so CallRunner can dispatch.
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: "{}", body_json: {
          "content" => [{ "type" => "text", "text" => "x" }],
          "model" => "claude-haiku-4-5-20251001",
          "usage" => { "input_tokens" => 1_000_000, "output_tokens" => 500_000 }
        }
      )
    end

    real_runner = Prouterd::Runner::CallRunner.new
    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: real_runner)
    run = orch.trigger(cost_doc, "p", input_event: {})
    fetched = repo.get_run_by_uid(run.uid)
    # 1M input @ 0.25 + 0.5M output @ 1.25 = 0.25 + 0.625 = 0.875
    expect(fetched.cost_usd).to be_within(0.001).of(0.875)
    expect(fetched.tokens_in).to eq(1_000_000)
    expect(fetched.tokens_out).to eq(500_000)
  end

  it "fails the block with cost_cap_exceeded when max-cost-usd is crossed" do
    cap_doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      prices anthropic
       model m in 100 out 100
      exit
      interface llm chat
       provider anthropic
       model m
      exit
      process p
       block ask
        interface llm chat
        prompt "ping"
        max-cost-usd 0.01
       exit
      exit
    PRC
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: "{}", body_json: {
          "content" => [{ "type" => "text", "text" => "x" }],
          "model" => "m",
          "usage" => { "input_tokens" => 1_000_000, "output_tokens" => 0 }
        }
      )
    end

    real_runner = Prouterd::Runner::CallRunner.new
    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: real_runner)
    run = orch.trigger(cap_doc, "p", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("cost_cap_exceeded")
  end

  it "honours `retry stop-on run.cost_usd gt N` after an attempt" do
    # Each attempt is a "successful" LLM call with fail-flagged output,
    # so retry-when keeps firing. Each attempt also bumps cost by
    # 1M * $1.00 / 1M = $1.00. With cap 2.50 USD, stop-on triggers
    # before max-attempts (5) are exhausted — expect ≤ 4 attempts.
    stop_doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      prices anthropic
       model m in 1.0 out 0.0
      exit
      policy budget_aware
       retry attempts 5
       retry backoff fixed
       retry initial-delay 1ms
       retry when output.text eq "fail"
       retry stop-on run.cost_usd gt 2.50
      exit
      interface llm chat
       provider anthropic
       model m
      exit
      process p
       block ask
        interface llm chat
        prompt "ping"
        retry budget_aware
       exit
      exit
    PRC
    allow(Prouterd::Iface::HttpClient).to receive(:request) do |**_|
      Prouterd::Iface::HttpClient::Response.new(
        status: 200, body_text: "{}", body_json: {
          "content" => [{ "type" => "text", "text" => "fail" }],
          "model" => "m",
          "usage" => { "input_tokens" => 1_000_000, "output_tokens" => 0 }
        }
      )
    end
    real_runner = Prouterd::Runner::CallRunner.new
    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: real_runner)
    run = orch.trigger(stop_doc, "p", input_event: {})
    fetched = repo.get_run_by_uid(run.uid)
    expect(fetched.cost_usd).to be > 2.50
    steps = repo.list_steps(run.id).select { |s| s.block_name == "ask" }
    expect(steps.length).to be <= 4
  end

  it "leaves tokens at 0 when no block produces a usage envelope" do
    runner.program("a", &Prouterd::Runner::StubRunner.success(output: { "ok" => 1 }))
    runner.program("b", &Prouterd::Runner::StubRunner.success(output: { "ok" => 2 }))

    run = orchestrator.trigger(document, "p", input_event: {})
    fetched = repo.get_run_by_uid(run.uid)
    expect(fetched.tokens_in).to eq(0)
    expect(fetched.tokens_out).to eq(0)
  end

  it "accepts the OpenAI-shape {prompt_tokens, completion_tokens} as a fallback" do
    runner.program("a") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "usage" => { "prompt_tokens" => 7, "completion_tokens" => 4 } },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    runner.program("b", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    fetched = repo.get_run_by_uid(run.uid)
    expect(fetched.tokens_in).to eq(7)
    expect(fetched.tokens_out).to eq(4)
  end
end
