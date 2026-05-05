require "spec_helper"

# Phase 35a: orphan container kill at boot.
#
# DockerRunner labels every container with prouterd.run_uid. If the
# daemon crashes mid-block, the container keeps running on the host
# even after the run row is swept to "failed" by Recovery. Phase 35a
# extends the recovery sweep to find containers labelled with run_uids
# that no longer correspond to a live run, and kill them via the new
# Runner::DockerStop module.
RSpec.describe Prouterd::Runtime::Recovery do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runs_repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  it "kills containers whose run_uid label is not in the live-run set" do
    # Create one run that's still 'running' WITH a queued job — the
    # earlier sweep stages skip a run with a live job, and our orphan
    # sweep then sees it as live.
    live_run = runs_repo.create_run(process_name: "p", input_event: {})
    runs_repo.update_run(live_run.id, status: "running",
                                       started_at: Time.now.utc.iso8601(3))
    Prouterd::Storage::Repositories::Jobs.new(db).enqueue(run_id: live_run.id, kind: "execute")

    # Two stale containers labelled with run_uids of nonexistent runs
    # → must be killed.
    stale1 = double("Container", info: { "Labels" => { "prouterd.run_uid" => "run_dead1" } })
    stale2 = double("Container", info: { "Labels" => { "prouterd.run_uid" => "run_dead2" } })
    allow(stale1).to receive(:json).and_return({})
    allow(stale2).to receive(:json).and_return({})

    # One live container — labelled with the still-running run's uid →
    # must NOT be killed.
    live_container = double("Container", info: { "Labels" => { "prouterd.run_uid" => live_run.uid } })
    allow(live_container).to receive(:json).and_return({})

    # Build a skeleton Docker module the recovery sweep can talk to.
    docker_mod = Module.new
    docker_mod.const_set(:Container, Class.new do
      class << self
        attr_accessor :all_response
        def all(*); all_response; end
      end
    end)
    docker_mod.const_set(:Error, Module.new {
      const_set(:DockerError, Class.new(StandardError))
    })
    stub_const("Docker", docker_mod)
    Docker::Container.all_response = [stale1, stale2, live_container]

    # Pretend docker-api is installed.
    allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)

    allow(Prouterd::Runner::DockerStop).to receive(:force_stop)

    result = described_class.sweep(db)
    expect(result.containers_killed).to eq(2)

    expect(Prouterd::Runner::DockerStop).to have_received(:force_stop).with(stale1).once
    expect(Prouterd::Runner::DockerStop).to have_received(:force_stop).with(stale2).once
    expect(Prouterd::Runner::DockerStop).not_to have_received(:force_stop).with(live_container)
  end

  it "is a no-op when docker-api is not installed" do
    allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(false)
    result = described_class.sweep(db)
    expect(result.containers_killed).to eq(0)
  end
end
