require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Runtime::WorkerPool do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs_repo) { Prouterd::Storage::Repositories::Jobs.new(db) }
  let(:runs_repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image x
      exit
      process pipeline
       block extract
        interface docker img1
       exit
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end

  def wait_for(deadline_seconds: 3)
    deadline = Time.now + deadline_seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  it "drains queued jobs and updates run status" do
    pool = described_class.new(store: store, runner: runner, workers: 2, logger: Prouterd::NullLogger.new)
    pool.run

    orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orchestrator.enqueue(document, "pipeline", input_event: {}, commit_id: store.running_commit.id)
    jobs_repo.enqueue(run_id: run.id)

    expect(wait_for { runs_repo.get_run(run.id).status == "success" }).to be(true)
    expect(jobs_repo.stats["completed"]).to eq(1)

    pool.stop
  end

  it "marks run failed when orchestrator raises" do
    runner.default { |_req| raise "boom" }

    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)
    pool.run

    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orch.enqueue(document, "pipeline", input_event: {}, commit_id: store.running_commit.id)
    jobs_repo.enqueue(run_id: run.id)

    expect(wait_for { runs_repo.get_run(run.id).status == "failed" }).to be(true)
    pool.stop
  end

  it "skips a run that was already canceled before the worker claimed it" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)

    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orch.enqueue(document, "pipeline", input_event: {}, commit_id: store.running_commit.id)
    jobs_repo.enqueue(run_id: run.id)
    runs_repo.update_run(run.id, status: "canceled", finished_at: Time.now.utc.iso8601(3))

    pool.run
    expect(wait_for { jobs_repo.stats["completed"] == 1 }).to be(true)
    expect(runner.calls).to be_empty # never executed
    pool.stop
  end

  it "handles execute_from_block payload" do
    doc2 = parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image x
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
    store.commit(doc2)

    runner.program("a", &Prouterd::Runner::StubRunner.success(output: { "first" => true }))
    runner.program("b") do |req|
      expect(req.input_json["context"]["seeded"]).to eq(true)
      Prouterd::Runner::StubRunner.success.call(req)
    end

    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orch.enqueue(doc2, "p", input_event: {}, commit_id: store.running_commit.id)
    jobs_repo.enqueue(run_id: run.id, kind: "execute_from_block",
                      payload: { "from_block" => "b", "seed_context" => { "seeded" => true } })

    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)
    pool.run
    expect(wait_for { runs_repo.get_run(run.id).status == "success" }).to be(true)
    pool.stop

    executed = runs_repo.list_steps(run.id).map(&:block_name)
    expect(executed).to eq(["b"])
  end
end
