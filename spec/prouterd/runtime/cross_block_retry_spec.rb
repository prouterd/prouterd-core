require "spec_helper"

# `retry when` predicate paths can now reference any block in the
# run context (not just the current block's `output.*`). When a
# policy's predicate references a downstream block, the orchestrator
# waits for that block to run, then evaluates the predicate; if it
# matches, the upstream block is re-executed (along with everything
# downstream-reachable from it). Bounded by the policy's
# retry_attempts cap.
#
# Use case: generator block `stage_verdict` + auditor block `verify`,
# where `verify.status eq "fail"` rewinds back to the generator.
RSpec.describe "cross-block-driven retry" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    src = <<~PRC
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      policy reflect_on_verdict
       retry attempts 3
       retry when verify.status eq "fail"
       retry feedback verify.issues into feedback
      exit
      process p
       block stage_verdict
        interface docker img1
        retry reflect_on_verdict
        command "regenerate, feedback={{previous.feedback}}"
       exit
       block verify
        interface docker img1
        command "audit"
       exit
       route stage_verdict verify
      exit
    PRC
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
  end

  it "rewinds to the upstream generator when the downstream verifier fails" do
    # Verify will return status=fail twice, then status=ok on the
    # third audit. stage_verdict should re-run each time. Total
    # stage_verdict attempts: 3 (initial + 2 retries triggered by
    # verify=fail × 2).
    verify_call = 0
    runner.program("verify") do
      verify_call += 1
      output = if verify_call < 3
                 { "status" => "fail", "issues" => ["missing dimension X"] }
               else
                 { "status" => "ok", "issues" => [] }
               end
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: output, artifacts: [], error_type: nil,
        error_message: nil, duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    stage_calls = []
    runner.program("stage_verdict") do |req|
      stage_calls << req.type_fields["command"]
      Prouterd::Runner::StubRunner.success(output: { "verdict" => "draft #{stage_calls.length}" }).call(req)
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    # 3 stage_verdict invocations, 3 verify invocations.
    expect(stage_calls.length).to eq(3)
    expect(verify_call).to eq(3)

    # The second + third stage_verdict calls saw the verifier's
    # `issues` array via `{{previous.feedback}}`. The first call had
    # no previous, so the templated command rendered with an empty
    # feedback.
    expect(stage_calls[0]).to include("feedback=")
    expect(stage_calls[1]).to include("missing dimension X")
    expect(stage_calls[2]).to include("missing dimension X")
  end

  it "respects retry_attempts: gives up and returns the run as failed when the verifier never passes" do
    runner.program("verify") do
      Prouterd::Runner::StubRunner.success(output: { "status" => "fail", "issues" => ["broken"] }).call(nil)
    end
    runner.program("stage_verdict", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    # retry_attempts=3 → initial + 2 outer retries → 3 stage_verdict
    # runs, 3 verify runs, then orchestrator gives up. Run is success
    # because no block returned a hard failure — the verifier just
    # never satisfied the predicate. Operator surface: the audit
    # trail (3 stage_verdict + 3 verify steps) tells the story.
    expect(run.status).to eq("success")

    steps = repo.list_steps(run.id)
    stage_steps = steps.select { |s| s.block_name == "stage_verdict" }
    verify_steps = steps.select { |s| s.block_name == "verify" }
    expect(stage_steps.length).to eq(3)
    expect(verify_steps.length).to eq(3)

    # System log records each cross-block retry trigger.
    logs = repo.list_logs(run.id).select { |l| l.stream == "system" }
    cross_block_lines = logs.select { |l| l.content.include?("cross-block retry-when") }
    expect(cross_block_lines.length).to eq(2)   # 2 retries triggered, 3rd attempt was the cap
  end

  it "leaves a same-block-only predicate untouched in the inner retry loop" do
    # `retry when output.X` still works exactly as before — no foreign
    # block in the path, so the cross-block sweep ignores it and the
    # inner per-block retry loop handles it.
    src = <<~PRC
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      policy own_only
       retry attempts 2
       retry when output.status eq "fail"
      exit
      process p
       block solo
        interface docker img1
        retry own_only
        command "go"
       exit
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))

    n = 0
    runner.program("solo") do
      n += 1
      output = n < 2 ? { "status" => "fail" } : { "status" => "ok" }
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: output, artifacts: [], error_type: nil,
        error_message: nil, duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(doc, "p", input_event: {})
    expect(run.status).to eq("success")
    expect(n).to eq(2)   # one inner retry on `output.status eq "fail"`
  end
end
