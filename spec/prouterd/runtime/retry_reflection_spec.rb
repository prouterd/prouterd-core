require "spec_helper"

# Phase 37e: retry-when on output.* + retry feedback for reflection loops.
RSpec.describe "reflection-loop retry: output predicates + feedback" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_REFLECT = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_REFLECT + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      policy reflect
       retry attempts 3
       retry backoff fixed
       retry initial-delay 1ms
       retry when output.verify eq "fail"
       retry feedback output.notes into feedback
      exit
      process p
       block analyze
        interface docker img1
        retry reflect
       exit
      exit
    PRC
  end

  it "fires a retry when a successful attempt's output predicate matches, then succeeds" do
    sequence = [
      { "verify" => "fail", "notes" => "be more specific" },
      { "verify" => "ok",   "notes" => "" }
    ]
    runner.program("analyze") do |req|
      out = sequence.shift
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: out, artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    steps = repo.list_steps(run.id)
    expect(steps.length).to eq(2)
    expect(steps.first.output_json).to include("\"fail\"")
    expect(steps.last.output_json).to include("\"ok\"")
  end

  it "exposes the prior attempt's feedback path under previous.<into> on retry" do
    feedback_doc = parse(<<~PRC)
      router demo
      exit
      policy reflect
       retry attempts 3
       retry backoff fixed
       retry initial-delay 1ms
       retry when output.verify eq "fail"
       retry feedback output.notes into feedback
      exit
      process p
       block analyze
        interface docker img1
        command "echo prev:{{previous.feedback}}"
        retry reflect
       exit
      exit
    PRC

    sequence = [
      { "verify" => "fail", "notes" => "weak: missing logs" },
      { "verify" => "ok" }
    ]
    runner.program("analyze") do |_req|
      out = sequence.shift
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: out, artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    orchestrator.trigger(feedback_doc, "p", input_event: {})

    expect(runner.calls.length).to eq(2)
    expect(runner.calls[0].type_fields["command"]).to eq("echo prev:")
    expect(runner.calls[1].type_fields["command"]).to eq("echo prev:weak: missing logs")
  end

  it "ends as a failed run with retry_when_unsatisfied when max attempts exhaust on a still-matching success" do
    runner.program("analyze") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "verify" => "fail", "notes" => "n/a" },
        artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("retry_when_unsatisfied")
  end
end
