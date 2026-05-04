require "spec_helper"

RSpec.describe "Phase 8 replay from block" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface docker img1
       image x
      exit
      process p
       block extract
        interface docker img1
       exit
       block enrich
        interface docker img1
       exit
       block notify
        interface docker img1
       exit
       route extract enrich
       route enrich notify
      exit
    PRC
  end

  before do
    store.commit(document)
  end

  it "starts execution at the chosen block, not from entry" do
    runner.program("extract", &Prouterd::Runner::StubRunner.success(output: { "name" => "Acme" }))
    runner.program("enrich",  &Prouterd::Runner::StubRunner.success(output: { "score" => 80 }))
    runner.program("notify",  &Prouterd::Runner::StubRunner.success(output: { "ok" => true }))

    original = orchestrator.trigger(
      document, "p",
      input_event: { "body" => "first" },
      commit_id: store.running_commit.id
    )
    expect(original.status).to eq("success")

    # Reset call log
    runner.calls.clear

    session = Prouterd::Shell::Session.new(store: store, runner: runner)
    replayed = session.replay_from(original.uid, "enrich")

    expect(replayed.status).to eq("success")
    # Replay should NOT have re-executed extract
    block_names = runner.calls.map(&:block_name)
    expect(block_names).to eq(%w[enrich notify])

    # And replayed run's steps reflect that
    expect(repo.list_steps(replayed.id).map(&:block_name)).to eq(%w[enrich notify])
  end

  it "seeds the replayed block's input from the original step's captured context" do
    runner.program("extract", &Prouterd::Runner::StubRunner.success(output: { "name" => "Acme" }))
    runner.program("enrich",  &Prouterd::Runner::StubRunner.success(output: { "score" => 80 }))
    runner.program("notify",  &Prouterd::Runner::StubRunner.success)

    original = orchestrator.trigger(
      document, "p",
      input_event: { "body" => "original-event" },
      commit_id: store.running_commit.id
    )

    runner.calls.clear
    captured = nil
    runner.program("enrich") do |req|
      captured = req
      Prouterd::Runner::StubRunner.success(output: { "score" => 99 }).call(req)
    end

    session = Prouterd::Shell::Session.new(store: store, runner: runner)
    session.replay_from(original.uid, "enrich")

    expect(captured.input_json["context"]["extract"]).to eq({ "name" => "Acme" })
  end

  it "errors when the block was never reached on the original run" do
    # Original run fails at extract → enrich never ran.
    runner.program("extract", &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit"))
    original = orchestrator.trigger(
      document, "p",
      input_event: {},
      commit_id: store.running_commit.id
    )
    expect(original.status).to eq("failed")

    session = Prouterd::Shell::Session.new(store: store, runner: runner)
    expect { session.replay_from(original.uid, "enrich") }
      .to raise_error(Prouterd::Shell::ShellError, /did not run in/)
  end

  it "errors on unknown block name" do
    runner.default(&Prouterd::Runner::StubRunner.success)
    original = orchestrator.trigger(
      document, "p",
      input_event: {},
      commit_id: store.running_commit.id
    )
    session = Prouterd::Shell::Session.new(store: store, runner: runner)
    expect { session.replay_from(original.uid, "ghost") }
      .to raise_error(Prouterd::Shell::ShellError, /did not run in/)
  end
end
