require "spec_helper"

# Phase 37g: pause + resume primitive for human-in-the-loop runs.
RSpec.describe "pause + resume" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_PAUSE = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_PAUSE + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       block fetch
        interface docker img1
       exit
       block approve
        pause "ok to deploy?"
       exit
       block apply_change
        interface docker img1
        command "echo decision={{approve.decision}}"
       exit
       route fetch approve
       route approve apply_change
      exit
    PRC
  end

  it "halts the run at a pause block, status=paused, and resumes from downstream after value injection" do
    runner.program("fetch",        &Prouterd::Runner::StubRunner.success)
    runner.program("apply_change", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("paused")

    paused_step = repo.list_steps(run.id).find { |s| s.status == "paused" }
    expect(paused_step.block_name).to eq("approve")

    resumed = orchestrator.resume_run(run.uid, document, value: { "decision" => "yes" })
    expect(resumed.status).to eq("success")

    steps = repo.list_steps(resumed.id)
    by_block = steps.group_by(&:block_name).transform_values(&:first)
    expect(by_block["approve"].status).to eq("success")
    expect(JSON.parse(by_block["approve"].output_json)).to eq("decision" => "yes")
    expect(by_block["apply_change"].status).to eq("success")
    expect(runner.calls.last.type_fields["command"]).to eq("echo decision=yes")
  end

  it "treats `prouter resume` on a non-paused run as an error" do
    runner.program("fetch",        &Prouterd::Runner::StubRunner.success)
    runner.program("apply_change", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    orchestrator.resume_run(run.uid, document, value: {})
    expect {
      orchestrator.resume_run(run.uid, document, value: {})
    }.to raise_error(Prouterd::Runtime::TriggerError, /not paused/)
  end

  it "succeeds immediately when the pause block has no downstream blocks" do
    terminal_doc = parse(<<~PRC)
      router demo
      exit
      process p
       block start
        interface docker img1
       exit
       block wait
        pause "approve?"
       exit
       route start wait
      exit
    PRC
    runner.program("start", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(terminal_doc, "p", input_event: {})
    expect(run.status).to eq("paused")

    resumed = orchestrator.resume_run(run.uid, terminal_doc, value: { "ok" => true })
    expect(resumed.status).to eq("success")
  end
end
