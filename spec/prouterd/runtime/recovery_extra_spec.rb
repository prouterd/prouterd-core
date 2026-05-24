require "spec_helper"
require "stringio"

# Covers the legacy / defensive paths inside Recovery: the jobs table
# missing (pre-Phase-11 DB), the orphan-container sweep error rescue,
# and the live_run_uids fallback for the same missing-jobs-table case.
RSpec.describe Prouterd::Runtime::Recovery do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runs_repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  describe "jobs table missing (legacy / pre-Phase-11 DB)" do
    before do
      # Force every code path that consults `jobs` to trip the rescue
      # branch. Targets:
      #   - sweep_jobs (line ~74)
      #   - sweep_steps (line ~101, falls through to sweep_steps_no_jobs_table)
      #   - sweep_runs  (line ~124, falls through to sweep_runs_no_jobs_table)
      #   - live_run_uids (line ~203 in sweep_orphan_containers)
      original = db.method(:execute)
      allow(db).to receive(:execute) do |sql, *args|
        if sql.is_a?(String) && sql.include?("jobs")
          raise SQLite3::SQLException, "no such table: jobs"
        end
        original.call(sql, *args)
      end
    end

    it "still sweeps running runs and running steps via the no-jobs-table fallback" do
      run = runs_repo.create_run(process_name: "p", input_event: {})
      runs_repo.update_run(run.id, status: "running",
                                   started_at: Time.now.utc.iso8601(3))
      step = runs_repo.create_step(run_id: run.id, block_name: "x")
      runs_repo.update_step(step.id, status: "running",
                                     started_at: Time.now.utc.iso8601(3))

      result = described_class.sweep(db)
      expect(result.runs_swept).to eq(1)
      expect(result.steps_swept).to eq(1)

      expect(runs_repo.get_run(run.id).status).to eq("failed")
      expect(runs_repo.get_step(step.id).status).to eq("failed")
    end

    it "sweep_steps_no_jobs_table is a no-op when nothing is in flight" do
      result = described_class.sweep(db)
      expect(result.runs_swept).to eq(0)
      expect(result.steps_swept).to eq(0)
    end

    it "live_run_uids falls back to runs table when sweep_orphan_containers runs" do
      # Set up a running run so live_run_uids returns its uid.
      live_run = runs_repo.create_run(process_name: "p", input_event: {})
      runs_repo.update_run(live_run.id, status: "running",
                                         started_at: Time.now.utc.iso8601(3))

      # Pretend docker is installed; serve one stale container so the
      # orphan-container kill path executes (forces live_run_uids to
      # be queried).
      stale = double("Container", info: { "Labels" => { "prouterd.run_uid" => "run_dead" } })
      allow(stale).to receive(:json).and_return({})

      docker_mod = Module.new
      docker_mod.const_set(:Container, Class.new do
        class << self
          attr_accessor :all_response
          def all(*); all_response; end
        end
      end)
      stub_const("Docker", docker_mod)
      Docker::Container.all_response = [stale]
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)
      allow(Prouterd::Runner::DockerStop).to receive(:force_stop)

      result = described_class.sweep(db)
      expect(result.containers_killed).to eq(1)
      expect(Prouterd::Runner::DockerStop).to have_received(:force_stop).with(stale)
    end
  end

  describe "orphan-container sweep rescues unexpected errors" do
    it "logs ORPHAN_FAIL and returns 0 when Docker.all raises" do
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)

      docker_mod = Module.new
      docker_mod.const_set(:Container, Class.new do
        class << self
          def all(*); raise StandardError, "docker socket down"; end
        end
      end)
      stub_const("Docker", docker_mod)

      out = StringIO.new
      result = described_class.sweep(db, logger: Prouterd::Logger.build(out))
      expect(result.containers_killed).to eq(0)
      expect(out.string).to match(/ORPHAN_FAIL/)
      expect(out.string).to match(/docker socket down/)
    end
  end

  describe "container with empty or missing prouterd.run_uid label" do
    it "skips containers without a usable run_uid" do
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)

      # Container with the label key but an empty value — covered by
      # `next if uid.nil? || uid.empty?`.
      empty_uid_container = double("Container",
                                   info: { "Labels" => { "prouterd.run_uid" => "" } })
      allow(empty_uid_container).to receive(:json).and_return({})

      docker_mod = Module.new
      docker_mod.const_set(:Container, Class.new do
        class << self
          attr_accessor :all_response
          def all(*); all_response; end
        end
      end)
      stub_const("Docker", docker_mod)
      Docker::Container.all_response = [empty_uid_container]
      allow(Prouterd::Runner::DockerStop).to receive(:force_stop)

      result = described_class.sweep(db)
      expect(result.containers_killed).to eq(0)
      expect(Prouterd::Runner::DockerStop).not_to have_received(:force_stop)
    end
  end
end
