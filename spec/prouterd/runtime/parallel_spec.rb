require "spec_helper"

# Phase 37j: declarative `parallel <name>` container with synthesized
# barrier block + member-output aggregation.
RSpec.describe "parallel <name> container" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_PAR = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_PAR + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       parallel evidence
        block fetch_jira
         interface docker img1
        exit
        block fetch_slack
         interface docker img1
        exit
        block fetch_sentry
         interface docker img1
        exit
       exit

       block analyze
        interface docker img1
        command "members={{evidence.succeeded}}"
       exit

       route evidence analyze
      exit
    PRC
  end

  it "runs all member blocks in parallel and aggregates outputs into the barrier" do
    runner.program("fetch_jira",   &Prouterd::Runner::StubRunner.success(output: { "issues" => 3 }))
    runner.program("fetch_slack",  &Prouterd::Runner::StubRunner.success(output: { "msgs" => 2 }))
    runner.program("fetch_sentry", &Prouterd::Runner::StubRunner.success(output: { "events" => 1 }))
    runner.program("analyze",      &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    steps = repo.list_steps(run.id)
    by_block = steps.group_by(&:block_name).transform_values(&:first)
    expect(by_block.keys).to include("fetch_jira", "fetch_slack", "fetch_sentry", "evidence", "analyze")
    expect(by_block["evidence"].status).to eq("success")

    aggregated = JSON.parse(by_block["evidence"].output_json)
    expect(aggregated["succeeded"]).to contain_exactly("fetch_jira", "fetch_slack", "fetch_sentry")
    expect(aggregated["members"]["fetch_jira"]).to eq("issues" => 3)
    expect(aggregated["members"]["fetch_slack"]).to eq("msgs" => 2)
  end

  it "with all-required: a single child failure aborts the run before the barrier" do
    runner.program("fetch_jira",   &Prouterd::Runner::StubRunner.success(output: { "ok" => true }))
    runner.program("fetch_slack",  &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "slack flaky"))
    runner.program("fetch_sentry", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("fetch_slack")

    steps = repo.list_steps(run.id).map(&:block_name)
    expect(steps).not_to include("evidence")  # barrier never ran
  end

  it "with all-best-effort: a child failure does not block the barrier; survivors flow through" do
    best_effort_doc = parse(<<~PRC)
      router demo
      exit
      process p
       parallel evidence
        join-strategy all-best-effort
        block fetch_jira
         interface docker img1
        exit
        block fetch_slack
         interface docker img1
        exit
       exit

       block analyze
        interface docker img1
       exit

       route evidence analyze
      exit
    PRC

    runner.program("fetch_jira",  &Prouterd::Runner::StubRunner.success(output: { "ok" => true }))
    runner.program("fetch_slack", &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))
    runner.program("analyze",     &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(best_effort_doc, "p", input_event: {})
    expect(run.status).to eq("success")

    steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
    aggregated = JSON.parse(steps["evidence"].output_json)
    expect(aggregated["succeeded"]).to eq(["fetch_jira"])
    expect(aggregated["failed"]).to eq(["fetch_slack"])
    expect(steps["analyze"].status).to eq("success")
  end
end
