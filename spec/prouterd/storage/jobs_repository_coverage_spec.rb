require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Jobs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }
  let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
  after { db.close }

  def make_run
    runs.create_run(process_name: "p", input_event: {})
  end

  describe "#requeue" do
    it "moves a locked job back to queued, clearing the lock holder" do
      r = make_run
      job = repo.enqueue(run_id: r.id)
      claimed = repo.claim("worker-1")
      expect(claimed.status).to eq("locked")

      repo.requeue(job.id)

      reloaded = repo.get(job.id)
      expect(reloaded.status).to eq("queued")
      expect(reloaded.locked_by).to be_nil
      expect(reloaded.locked_at).to be_nil
    end

    it "honors an explicit available_at" do
      r = make_run
      job = repo.enqueue(run_id: r.id)
      future = Time.now + 600
      repo.requeue(job.id, available_at: future)
      reloaded = repo.get(job.id)
      # Stored to ms precision.
      expect(Time.iso8601(reloaded.available_at)).to be_within(1).of(future)
    end
  end

  describe "#list" do
    it "without a status filter returns the most recent jobs first (no-status branch)" do
      r = make_run
      j1 = repo.enqueue(run_id: r.id)
      j2 = repo.enqueue(run_id: r.id)
      rows = repo.list
      ids = rows.map(&:id)
      expect(ids).to include(j1.id, j2.id)
      expect(ids.first).to be > ids.last # newest first
    end

    it "filters by status when given (status-branch path)" do
      r = make_run
      j1 = repo.enqueue(run_id: r.id)
      _claimed = repo.claim("worker-1")
      # j1 is now 'locked'.
      j2 = repo.enqueue(run_id: r.id)

      queued = repo.list(status: "queued").map(&:id)
      locked = repo.list(status: "locked").map(&:id)
      expect(queued).to include(j2.id)
      expect(queued).not_to include(j1.id)
      expect(locked).to include(j1.id)
      expect(locked).not_to include(j2.id)
    end

    it "honors the limit" do
      r = make_run
      3.times { repo.enqueue(run_id: r.id) }
      expect(repo.list(limit: 2).size).to eq(2)
    end
  end
end
