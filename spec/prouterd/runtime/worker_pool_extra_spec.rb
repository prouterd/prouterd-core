require "spec_helper"
require "stringio"

# Covers the defensive paths in WorkerPool that the happy-path spec
# doesn't reach: claim() raising, run row missing between enqueue and
# claim, config commit missing, load_running fallback (no commit_id),
# and the unknown-job-kind build_execute_kwargs else branch.
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
      process p
       block a
        interface docker img1
       exit
      exit
    PRC
  end

  before { store.commit(document) }

  def wait_for(deadline_seconds: 3)
    deadline = Time.now + deadline_seconds
    until Time.now > deadline
      return true if yield
      sleep 0.02
    end
    false
  end

  it "logs and recovers when Jobs#claim raises a transient error" do
    out = StringIO.new
    logger = Prouterd::Logger.build(out)
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: logger)

    raised = false
    # Make the first claim attempt raise, then return nil afterwards
    # so the loop keeps spinning until @stopping is set.
    allow_any_instance_of(Prouterd::Storage::Repositories::Jobs).to receive(:claim) do |*|
      unless raised
        raised = true
        raise StandardError, "transient db hiccup"
      end
      nil
    end

    pool.run
    expect(wait_for { out.string.include?("CLAIM_ERR") }).to be(true)
    pool.stop

    expect(out.string).to match(/CLAIM_ERR/)
    expect(out.string).to match(/transient db hiccup/)
  end

  it "fails the job when the run row no longer exists" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)

    # Create a real run so the FK in `jobs` passes, then mock get_run
    # to return nil for that id — simulating an operator purging the
    # row between enqueue and claim.
    real_run = runs_repo.create_run(process_name: "p", input_event: {})
    job = jobs_repo.enqueue(run_id: real_run.id)

    allow_any_instance_of(Prouterd::Storage::Repositories::Runs)
      .to receive(:get_run).and_wrap_original do |orig, id|
        id == real_run.id ? nil : orig.call(id)
      end

    pool.run
    expect(wait_for { jobs_repo.get(job.id).status == "failed" }).to be(true)
    pool.stop

    expect(jobs_repo.get(job.id).error_message).to match(/no longer exists/)
  end

  it "marks run failed when the pinned config commit is unavailable" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)

    # Pin to a real commit so the FK succeeds, then stub get_commit to
    # return nil — simulates a commit row missing at worker dispatch.
    real_commit_id = store.running_commit.id
    run = runs_repo.create_run(
      process_name: "p",
      process_config_commit_id: real_commit_id,
      input_event: {}
    )
    allow(store).to receive(:get_commit).with(real_commit_id).and_return(nil)
    job = jobs_repo.enqueue(run_id: run.id)

    pool.run
    expect(wait_for { jobs_repo.get(job.id).status == "failed" }).to be(true)
    pool.stop

    refreshed_run = runs_repo.get_run(run.id)
    expect(refreshed_run.status).to eq("failed")
    expect(refreshed_run.error_summary).to match(/config commit unavailable/)
    expect(jobs_repo.get(job.id).error_message).to match(/config commit/)
  end

  it "falls back to store.load_running when the run has no pinned commit id" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)
    runner.default(&Prouterd::Runner::StubRunner.success)

    # Create a run with no pinned commit (replicates legacy path).
    run = runs_repo.create_run(process_name: "p", input_event: {})
    jobs_repo.enqueue(run_id: run.id)

    pool.run
    expect(wait_for { runs_repo.get_run(run.id).status == "success" }).to be(true)
    pool.stop
  end

  it "rescues a Runs repo construction failure so jobs.fail still runs" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)
    run = runs_repo.create_run(process_name: "p", input_event: {})
    job = jobs_repo.enqueue(run_id: run.id)

    # Make line 79's `Storage::Repositories::Runs.new(@store.db)` raise
    # so runs_repo stays nil; the rescue block's `runs_repo&.update_run`
    # then takes the `nil` branch (else: 0) instead of the happy path.
    call_count = 0
    original = Prouterd::Storage::Repositories::Runs.method(:new)
    allow(Prouterd::Storage::Repositories::Runs).to receive(:new) do |arg|
      call_count += 1
      raise "ctor blew up" if call_count == 1

      original.call(arg)
    end

    pool.run
    expect(wait_for { jobs_repo.get(job.id).status == "failed" }).to be(true)
    pool.stop

    expect(jobs_repo.get(job.id).error_message).to include("ctor blew up")
  end

  it "returns empty kwargs for an unrecognized job kind" do
    pool = described_class.new(store: store, runner: runner, workers: 1, logger: Prouterd::NullLogger.new)
    runner.default(&Prouterd::Runner::StubRunner.success)

    run = runs_repo.create_run(
      process_name: "p",
      process_config_commit_id: store.running_commit.id,
      input_event: {}
    )
    # `mystery` is neither "execute" nor "execute_from_block" — hits the
    # else branch in build_execute_kwargs, returning {} which is what
    # execute_run uses for from_block/seed_context defaults.
    jobs_repo.enqueue(run_id: run.id, kind: "mystery")

    pool.run
    expect(wait_for { runs_repo.get_run(run.id).status == "success" }).to be(true)
    pool.stop
  end
end
