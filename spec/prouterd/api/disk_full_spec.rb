require "spec_helper"
require "rack/test"

# Phase 34a: disk-full propagation.
#
# When SQLite raises an I/O / no-space exception mid-handler, the App
# must:
#   1. translate it into a 503 with error_type "storage_unavailable"
#   2. flip its accepting flag off so the NEXT request fails fast
#   3. not leave behind a partially-written run row
#
# We don't touch a real ENOSPC; we inject the failure mid-second-write
# by stubbing `Storage::Repositories::Jobs#enqueue` to raise after the
# orchestrator already inserted the run row. With the Phase 34a
# transaction wrapper around both writes, the run insert rolls back —
# so the table is clean.
RSpec.describe "Phase 34a disk-unavailable handling" do
  include Rack::Test::Methods

  let(:db)        { Prouterd::Storage::DB.open(":memory:") }
  let(:store)     { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner)    { Prouterd::Runner::StubRunner.new }
  let(:jobs)      { Prouterd::Storage::Repositories::Jobs.new(db) }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics)   { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:app) do
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics, admin_token: nil
    )
  end

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface webhook leads_in
       path /leads
       method POST
       no shutdown
      exit
      interface shell host
      exit
      process pipeline
       block extract
        interface shell host
       exit
      exit
      route interface leads_in process pipeline
      exit
    PRC
  end

  before { store.commit(document) }

  it "rolls back the run row + flips accepting=false on a mid-pair storage failure" do
    runs_repo = Prouterd::Storage::Repositories::Runs.new(db)

    # First call to jobs.enqueue (after the orchestrator inserted the run)
    # raises a disk-unavailable exception. The transaction wrapper rolls
    # back; no orphan run row should remain.
    fail_once = true
    allow_any_instance_of(Prouterd::Storage::Repositories::Jobs)
      .to receive(:enqueue).and_wrap_original do |original, *args, **kwargs|
        if fail_once
          fail_once = false
          raise Prouterd::Storage::DiskUnavailableError,
                "simulated mid-pair storage failure"
        end
        original.call(*args, **kwargs)
      end

    header "content-type", "application/json"
    post "/i/leads_in", JSON.dump(type: "lead.created")

    expect(last_response.status).to eq(503)
    body = JSON.parse(last_response.body)
    expect(body["error"]["code"]).to eq("storage_unavailable")

    # No orphan run row.
    expect(runs_repo.list_runs).to be_empty

    # App flipped to not-accepting; next request short-circuits to 503.
    expect(app.accepting?).to be(false)
    post "/i/leads_in", JSON.dump(type: "lead.created")
    expect(last_response.status).to eq(503)
  end

  it "DB#healthy? returns true on a working :memory: DB" do
    expect(db.healthy?).to be(true)
  end
end
