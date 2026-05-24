require "spec_helper"

# Cross-block `retry when` over a merge barrier. Without the sweep
# purging next_ready, the barrier's eager enqueue from the previous
# level would fire it on stale or empty member context — recording
# permanently empty output_json on the first outer-retry pass, and
# every downstream block reading `{{barrier.field}}` would see {}.
RSpec.describe "cross-block retry through a merge barrier" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      policy reflect
       retry attempts 3
       retry when verify.status eq "fail"
      exit
      process p
       block planner
        interface docker img1
        retry reflect
       exit
       block verify
        interface docker img1
       exit
       block audit
        interface docker img1
       exit

       merge pair
        from verify, audit
        strategy all-best-effort
       exit

       block sink
        interface docker img1
       exit

       route planner verify
       route pair sink
      exit
    PRC
  end

  it "barrier fires only on the final pass with fresh member context" do
    planner_calls = 0
    verify_calls  = 0
    audit_calls   = 0

    runner.program("planner") do |req|
      planner_calls += 1
      Prouterd::Runner::StubRunner.success(output: { "draft" => "v#{planner_calls}" }).call(req)
    end
    runner.program("verify") do |req|
      verify_calls += 1
      status = verify_calls < 2 ? "fail" : "ok"
      Prouterd::Runner::StubRunner.success(output: { "status" => status, "draft_seen" => "v#{planner_calls}" }).call(req)
    end
    runner.program("audit") do |req|
      audit_calls += 1
      Prouterd::Runner::StubRunner.success(output: { "audit_count" => audit_calls }).call(req)
    end
    runner.program("sink", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    # planner ran twice (initial + 1 outer retry triggered by
    # verify.status=fail). verify ran twice in lockstep. audit only
    # ran once — it's a sibling of verify in the merge, but only
    # verify is downstream-reachable from planner, so the sweep
    # cleared verify+pair+sink but NOT audit. Audit's first run still
    # counts toward the final barrier (audit_calls remains 1 in
    # output).
    expect(planner_calls).to eq(2)
    expect(verify_calls).to eq(2)
    expect(audit_calls).to eq(1)

    steps = repo.list_steps(run.id)
    pair_steps = steps.select { |s| s.block_name == "pair" }
    # Critical assertion: the barrier fires exactly ONCE, on the
    # final pass — without the next_ready purge, it would have fired
    # on the stale first-pass level too, recording an empty/fail
    # aggregate.
    expect(pair_steps.length).to eq(1)
    output = JSON.parse(pair_steps.first.output_json)
    expect(output["members"]["verify"]).to eq("status" => "ok", "draft_seen" => "v2")
    expect(output["members"]["audit"]).to eq("audit_count" => 1)
    expect(output["succeeded"]).to contain_exactly("verify", "audit")
  end
end
