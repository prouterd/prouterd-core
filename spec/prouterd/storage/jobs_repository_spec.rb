require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Jobs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }
  let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def make_run
    runs.create_run(process_name: "p", input_event: {})
  end

  describe "enqueue + get" do
    it "creates a queued job" do
      run = make_run
      job = repo.enqueue(run_id: run.id)
      expect(job.run_id).to eq(run.id)
      expect(job.status).to eq("queued")
      expect(job.attempts).to eq(0)
      expect(repo.get(job.id)).not_to be_nil
    end

    it "stores kind + payload" do
      run = make_run
      job = repo.enqueue(run_id: run.id, kind: "execute_from_block",
                         payload: { "from_block" => "enrich", "seed_context" => { "lead" => {} } })
      expect(job.kind).to eq("execute_from_block")
      expect(job.payload["from_block"]).to eq("enrich")
    end
  end

  describe "claim" do
    it "claims the next queued job atomically" do
      r1 = make_run
      r2 = make_run
      j1 = repo.enqueue(run_id: r1.id)
      j2 = repo.enqueue(run_id: r2.id)

      claimed1 = repo.claim("worker-1")
      expect(claimed1.id).to eq(j1.id)
      expect(claimed1.status).to eq("locked")
      expect(claimed1.locked_by).to eq("worker-1")
      expect(claimed1.attempts).to eq(1)

      claimed2 = repo.claim("worker-2")
      expect(claimed2.id).to eq(j2.id)
    end

    it "returns nil when nothing is queued" do
      expect(repo.claim("worker-x")).to be_nil
    end

    it "skips not-yet-available jobs" do
      run = make_run
      future = (Time.now + 60).utc.iso8601(3)
      repo.enqueue(run_id: run.id, available_at: Time.now + 60)
      expect(repo.claim("worker-x")).to be_nil
    end

    it "is race-safe under concurrent workers" do
      runs_arr = Array.new(20) { make_run }
      runs_arr.each { |r| repo.enqueue(run_id: r.id) }

      claimed = []
      mutex = Mutex.new
      threads = 4.times.map do |i|
        Thread.new do
          loop do
            j = repo.claim("worker-#{i}")
            break unless j

            mutex.synchronize { claimed << j.id }
          end
        end
      end
      threads.each(&:join)

      expect(claimed.length).to eq(20)
      expect(claimed.uniq.length).to eq(20)
    end
  end

  describe "complete + fail" do
    it "complete marks a job and clears the lock" do
      job = repo.enqueue(run_id: make_run.id)
      repo.claim("w")
      repo.complete(job.id)
      refreshed = repo.get(job.id)
      expect(refreshed.status).to eq("completed")
      expect(refreshed.locked_by).to be_nil
    end

    it "fail records the error_message" do
      job = repo.enqueue(run_id: make_run.id)
      repo.claim("w")
      repo.fail(job.id, "boom")
      expect(repo.get(job.id).status).to eq("failed")
      expect(repo.get(job.id).error_message).to eq("boom")
    end
  end

  describe "requeue_abandoned" do
    it "moves locked jobs older than threshold back to queued" do
      run = make_run
      job = repo.enqueue(run_id: run.id)
      repo.claim("w-dead") # locked

      # Pretend the lock was acquired long ago.
      old = (Time.now - 120).utc.iso8601(3)
      db.execute("UPDATE jobs SET locked_at = ? WHERE id = ?", [old, job.id])

      ids = repo.requeue_abandoned(threshold_seconds: 60)
      expect(ids).to eq([job.id])
      refreshed = repo.get(job.id)
      expect(refreshed.status).to eq("queued")
      expect(refreshed.locked_by).to be_nil
    end

    it "leaves recently-locked jobs alone" do
      run = make_run
      repo.enqueue(run_id: run.id)
      repo.claim("w-live")

      ids = repo.requeue_abandoned(threshold_seconds: 60)
      expect(ids).to be_empty
    end
  end

  describe "stats" do
    it "counts by status" do
      r1 = make_run
      r2 = make_run
      repo.enqueue(run_id: r1.id)
      claimed = repo.claim("w")
      repo.enqueue(run_id: r2.id)

      stats = repo.stats
      expect(stats["queued"]).to eq(1)
      expect(stats["locked"]).to eq(1)
    end
  end
end
