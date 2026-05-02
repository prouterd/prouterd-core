require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Runtime::Recovery do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  it "is a no-op on a fresh database" do
    result = described_class.sweep(db)
    expect(result.runs_swept).to eq(0)
    expect(result.steps_swept).to eq(0)
  end

  it "marks abandoned running runs as failed" do
    run = repo.create_run(process_name: "p", input_event: {})
    repo.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))

    out = StringIO.new
    described_class.sweep(db, output: out)

    refreshed = repo.get_run(run.id)
    expect(refreshed.status).to eq("failed")
    expect(refreshed.error_summary).to include("orchestrator restart")
    expect(refreshed.finished_at).not_to be_nil
    expect(out.string).to include("recovery: marked")
  end

  it "marks abandoned queued runs as failed" do
    run = repo.create_run(process_name: "p", input_event: {})
    # status defaults to "queued"
    described_class.sweep(db)
    expect(repo.get_run(run.id).status).to eq("failed")
  end

  it "leaves terminal runs alone" do
    run = repo.create_run(process_name: "p", input_event: {})
    repo.update_run(run.id, status: "success", finished_at: Time.now.utc.iso8601(3))

    described_class.sweep(db)
    expect(repo.get_run(run.id).status).to eq("success")
  end

  it "marks abandoned running steps as failed" do
    run = repo.create_run(process_name: "p", input_event: {})
    step = repo.create_step(run_id: run.id, block_name: "x")
    repo.update_step(step.id, status: "running", started_at: Time.now.utc.iso8601(3))

    described_class.sweep(db)
    refreshed = repo.get_step(step.id)
    expect(refreshed.status).to eq("failed")
    expect(refreshed.error_type).to eq("abandoned")
    expect(refreshed.error_message).to include("orchestrator restart")
  end

  it "does not touch completed steps" do
    run = repo.create_run(process_name: "p", input_event: {})
    step = repo.create_step(run_id: run.id, block_name: "x")
    repo.update_step(step.id, status: "success")

    described_class.sweep(db)
    expect(repo.get_step(step.id).status).to eq("success")
  end
end
