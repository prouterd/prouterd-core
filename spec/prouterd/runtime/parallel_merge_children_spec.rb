require "spec_helper"

# `join-strategy merge-children` makes the barrier output a shallow
# merge of every member's output_json (no member-name keying), so a
# parallel group can satisfy a contract whose shape is the union of
# its children's outputs. Failed children are skipped (best-effort
# semantics); barrier always succeeds.
RSpec.describe "parallel join-strategy merge-children" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_MERGE = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_MERGE + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       parallel health_checks
        join-strategy merge-children
        block check_jira
         interface docker img1
        exit
        block check_slack
         interface docker img1
        exit
        block check_sentry
         interface docker img1
        exit
       exit

       block consume
        interface docker img1
        command "got {{health_checks.jira}} {{health_checks.slack}} {{health_checks.sentry}}"
       exit

       route health_checks consume
      exit
    PRC
  end

  it "shallow-merges every child's output into a single flat object" do
    runner.program("check_jira",   &Prouterd::Runner::StubRunner.success(output: { "jira"   => "ok" }))
    runner.program("check_slack",  &Prouterd::Runner::StubRunner.success(output: { "slack"  => "ok" }))
    runner.program("check_sentry", &Prouterd::Runner::StubRunner.success(output: { "sentry" => "ok" }))
    runner.program("consume",      &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    barrier_step = repo.list_steps(run.id).find { |s| s.block_name == "health_checks" }
    aggregated = JSON.parse(barrier_step.output_json)
    expect(aggregated).to eq(
      "jira"   => "ok",
      "slack"  => "ok",
      "sentry" => "ok"
    )
    # Wrapper keys (`members`, `succeeded`, `failed`) are NOT present —
    # that's the whole point of merge-children.
    expect(aggregated).not_to have_key("members")
    expect(aggregated).not_to have_key("succeeded")
  end

  it "is best-effort: a failed child is dropped from the merge, barrier still succeeds" do
    runner.program("check_jira",   &Prouterd::Runner::StubRunner.success(output: { "jira"  => "ok"   }))
    runner.program("check_slack",  &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "down"))
    runner.program("check_sentry", &Prouterd::Runner::StubRunner.success(output: { "sentry" => "ok" }))
    runner.program("consume",      &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    barrier_step = repo.list_steps(run.id).find { |s| s.block_name == "health_checks" }
    aggregated = JSON.parse(barrier_step.output_json)
    expect(aggregated).to eq("jira" => "ok", "sentry" => "ok")
    expect(aggregated).not_to have_key("slack")
  end

  it "ignores non-Hash member outputs cleanly" do
    runner.program("check_jira",  &Prouterd::Runner::StubRunner.success(output: { "jira" => "ok" }))
    runner.program("check_slack", &Prouterd::Runner::StubRunner.success(output: { "slack" => "ok" }))
    # sentry returns a non-Hash output (legal but exotic — don't crash on it).
    runner.program("check_sentry") do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: "just-a-string",
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    runner.program("consume", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    barrier_step = repo.list_steps(run.id).find { |s| s.block_name == "health_checks" }
    aggregated = JSON.parse(barrier_step.output_json)
    expect(aggregated).to eq("jira" => "ok", "slack" => "ok")
  end

  it "round-trips through render → parse" do
    rendered = Prouterd::Config::Renderer.render(document)
    expect(rendered).to include("join-strategy merge-children")
    again = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(rendered))
    expect(Prouterd::Config::Renderer.render(again)).to eq(rendered)
  end
end
