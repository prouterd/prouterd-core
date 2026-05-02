require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Runs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }

  after { db.close }

  describe "runs" do
    it "creates a run with a unique uid" do
      run = repo.create_run(process_name: "p", input_event: { "type" => "x" })
      expect(run.uid).to match(/\Arun_[0-9a-f]{8}\z/)
      expect(run.process_name).to eq("p")
      expect(run.status).to eq("queued")
      expect(run.input_event_json).to eq('{"type":"x"}')
    end

    it "fetches by id and uid" do
      run = repo.create_run(process_name: "p", input_event: {})
      expect(repo.get_run(run.id).uid).to eq(run.uid)
      expect(repo.get_run_by_uid(run.uid).id).to eq(run.id)
    end

    it "update_run rewrites status and timestamps" do
      run = repo.create_run(process_name: "p", input_event: {})
      updated = repo.update_run(run.id, status: "success", finished_at: "2026-01-01T00:00:00.000Z")
      expect(updated.status).to eq("success")
      expect(updated.finished_at).to eq("2026-01-01T00:00:00.000Z")
    end

    it "list_runs is newest-first and filters by process" do
      a = repo.create_run(process_name: "alpha", input_event: {})
      b = repo.create_run(process_name: "beta",  input_event: {})
      c = repo.create_run(process_name: "alpha", input_event: {})
      all = repo.list_runs.map(&:id)
      expect(all).to eq([c.id, b.id, a.id])

      filtered = repo.list_runs(process_name: "alpha").map(&:id)
      expect(filtered).to eq([c.id, a.id])
    end
  end

  describe "steps" do
    it "creates a step in pending status" do
      run = repo.create_run(process_name: "p", input_event: {})
      step = repo.create_step(run_id: run.id, block_name: "extract", image: "alpine:1")
      expect(step.status).to eq("pending")
      expect(step.image).to eq("alpine:1")
      expect(step.attempt).to eq(1)
    end

    it "list_steps returns by run in insertion order" do
      run = repo.create_run(process_name: "p", input_event: {})
      a = repo.create_step(run_id: run.id, block_name: "a")
      b = repo.create_step(run_id: run.id, block_name: "b")
      ids = repo.list_steps(run.id).map(&:id)
      expect(ids).to eq([a.id, b.id])
    end
  end

  describe "logs" do
    it "appends and lists logs" do
      run = repo.create_run(process_name: "p", input_event: {})
      step = repo.create_step(run_id: run.id, block_name: "b")
      repo.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: "hello")
      repo.append_log(run_id: run.id, step_id: step.id, stream: "stderr", content: "warn")
      logs = repo.list_logs(run.id)
      expect(logs.length).to eq(2)
      expect(logs.map(&:stream)).to eq(%w[stdout stderr])
    end

    it "skips empty content" do
      run = repo.create_run(process_name: "p", input_event: {})
      repo.append_log(run_id: run.id, stream: "stdout", content: "")
      expect(repo.list_logs(run.id)).to be_empty
    end
  end

  describe "artifacts" do
    it "persists and lists artifacts per run/step" do
      run = repo.create_run(process_name: "p", input_event: {})
      step = repo.create_step(run_id: run.id, block_name: "b")
      repo.add_artifact(
        run_id: run.id, step_id: step.id, block_name: "b",
        name: "out.json", path: "/var/x/out.json", size_bytes: 42, checksum: "abc"
      )
      arts = repo.list_artifacts(run.id)
      expect(arts.length).to eq(1)
      expect(arts.first.name).to eq("out.json")
    end
  end
end
