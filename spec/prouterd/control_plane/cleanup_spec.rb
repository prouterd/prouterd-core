require "spec_helper"
require "tempfile"
require "fileutils"

RSpec.describe Prouterd::ControlPlane::Cleanup do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def make_run(status:, age_seconds:, with_step: true)
    run = repo.create_run(process_name: "p", input_event: {})
    started = (Time.now - age_seconds).utc.iso8601(3)
    finished = %w[success failed canceled timeout].include?(status) ? started : nil
    repo.update_run(run.id, status: status, started_at: started, finished_at: finished)
    db.execute("UPDATE runs SET created_at = ? WHERE id = ?", [started, run.id])
    if with_step
      step = repo.create_step(run_id: run.id, block_name: "b")
      repo.update_step(step.id, status: status)
      repo.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: "hi")
      repo.add_artifact(
        run_id: run.id, step_id: step.id, block_name: "b",
        name: "x.json", path: "/tmp/prouterd-cleanup-test/x.json",
        size_bytes: 10, checksum: "abc"
      )
    end
    run
  end

  it "is a no-op when nothing matches the threshold" do
    make_run(status: "success", age_seconds: 60) # too recent
    result = described_class.sweep(db, older_than: 3600)
    expect(result.runs).to eq(0)
  end

  it "deletes terminal runs older than the threshold" do
    old = make_run(status: "success", age_seconds: 7200)
    new = make_run(status: "success", age_seconds: 60)

    result = described_class.sweep(db, older_than: 3600)
    expect(result.runs).to eq(1)
    expect(result.steps).to eq(1)
    expect(result.logs).to eq(1)
    expect(result.artifacts).to eq(1)

    expect(repo.get_run(old.id)).to be_nil
    expect(repo.get_run(new.id)).not_to be_nil
  end

  it "leaves non-terminal runs alone even if old" do
    in_flight = repo.create_run(process_name: "p", input_event: {})
    old_started = (Time.now - 7200).utc.iso8601(3)
    repo.update_run(in_flight.id, status: "running", started_at: old_started)
    db.execute("UPDATE runs SET created_at = ? WHERE id = ?", [old_started, in_flight.id])

    result = described_class.sweep(db, older_than: 3600)
    expect(result.runs).to eq(0)
    expect(repo.get_run(in_flight.id)).not_to be_nil
  end

  it "dry-run reports counts but does not delete" do
    old = make_run(status: "failed", age_seconds: 7200)

    result = described_class.sweep(db, older_than: 3600, dry_run: true)
    expect(result.would_delete).to be(true)
    expect(result.runs).to eq(1)
    expect(repo.get_run(old.id)).not_to be_nil
  end

  it "removes on-disk artifact directories for swept runs" do
    Dir.mktmpdir("prouterd-cleanup-test-") do |root|
      run = make_run(status: "success", age_seconds: 7200)

      run_dir = File.join(root, run.uid, "b")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "out.json"), "hello")

      result = described_class.sweep(db, older_than: 3600, artifact_root: root)
      expect(result.artifact_files).to eq(1)
      expect(File.exist?(File.join(run_dir, "out.json"))).to be(false)
      expect(File.directory?(File.join(root, run.uid))).to be(false)
    end
  end
end
