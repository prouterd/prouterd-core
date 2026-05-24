require "spec_helper"

# Cover every RPC method route the base spec doesn't reach plus the
# forward_text non-2xx path, the inner-not-a-Hash error envelope
# fallback, and the FakeRequest helper accessors.
RSpec.describe Prouterd::API::RpcDispatcher do
  let(:db)        { Prouterd::Storage::DB.open(":memory:") }
  let(:store)     { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner)    { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics)   { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:jobs)      { Prouterd::Storage::Repositories::Jobs.new(db) }

  let(:app) do
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics, admin_token: nil
    )
  end
  let(:v1) { app.instance_variable_get(:@v1) }

  subject(:dispatcher) { described_class.new(v1: v1, app: app, store: store) }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      queue default
       concurrency 2
       timeout 30s
      exit
      tool sentiment
       description "score sentiment"
       args text
      exit
      interface docker img1
       image alpine:1
      exit
      process pipeline
       queue default
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
  after { db.close }

  describe "every RPC route" do
    it "tools.list returns the declared tools" do
      r = dispatcher.call("tools.list", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"].first["name"]).to eq("sentiment")
    end

    it "config.startup is a forward_text 404 when no startup commit exists" do
      r = dispatcher.call("config.startup", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("not_found")
    end

    it "config.startup with a blessed startup commit returns the rendered DSL as a bare string" do
      store.write_memory
      r = dispatcher.call("config.startup", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]).to be_a(String)
      expect(r[:payload]).to include("router demo")
    end

    it "config.commit returns a single commit's payload" do
      commit_id = store.running_commit.id
      r = dispatcher.call("config.commit", { "id" => commit_id })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["id"]).to eq(commit_id)
    end

    it "config.save_boot blesses the running commit" do
      r = dispatcher.call("config.save_boot", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["commit_id"]).to be_a(Integer)
    end

    it "processes.trigger enqueues a run" do
      r = dispatcher.call("processes.trigger", { "name" => "pipeline", "event" => { "type" => "x" } })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["run_id"]).to match(/\Arun_/)
    end

    it "runs.get returns one run by uid" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      r = dispatcher.call("runs.get", { "uid" => run.uid })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["uid"]).to eq(run.uid)
    end

    it "runs.cancel marks a queued run canceled" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      r = dispatcher.call("runs.cancel", { "uid" => run.uid })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["status"]).to eq("canceled")
    end

    it "runs.replay creates a child replay run with from_block carried through" do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      r = dispatcher.call("runs.replay", { "uid" => original.uid })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["replay_of"]).to eq(original.uid)
    end

    it "runs.replay forwards from_block when supplied" do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      r = dispatcher.call("runs.replay", { "uid" => original.uid, "from_block" => "extract" })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]["from"]).to eq("extract")
    end

    it "runs.resume returns not_found when uid is unknown" do
      r = dispatcher.call("runs.resume", { "uid" => "run_does_not_exist", "value" => {} })
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("not_found")
    end

    it "runs.artifacts returns an empty data array when the run has none" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      r = dispatcher.call("runs.artifacts", { "uid" => run.uid })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]).to eq([])
    end

    it "runs.logs returns logs (empty for the freshly-created run)" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      r = dispatcher.call("runs.logs", { "uid" => run.uid })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]).to eq([])
    end

    it "trace passes interface through into the body when supplied" do
      r = dispatcher.call("trace", { "event" => { "type" => "x" }, "interface" => "no-such-iface" })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]).to have_key("interface")
    end
  end

  describe "forward_text non-2xx fallback" do
    it "config.running returns an error tuple if the underlying call replies non-2xx" do
      # Make get_config_running fall through to a 503 via the v1 surface
      # by stubbing it to return a plain text 503.
      allow(v1).to receive(:get_config_running).and_return(
        [503, { "content-type" => "text/plain" }, ["nope"]]
      )
      r = dispatcher.call("config.running", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("unavailable")
    end
  end

  describe "forward_json envelope fallbacks" do
    it "uses ERROR_FOR_STATUS when the body has no `error` envelope at all" do
      allow(v1).to receive(:get_processes).and_return(
        [410, { "content-type" => "application/json" }, [JSON.dump(error: "old code path")]]
      )
      r = dispatcher.call("processes.list", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("gone")
      expect(r[:payload][:message]).to eq("old code path")
    end

    it "falls back to a generic message if neither envelope nor inner text is present" do
      allow(v1).to receive(:get_processes).and_return(
        [502, { "content-type" => "application/json" }, [JSON.dump(error: "")]]
      )
      r = dispatcher.call("processes.list", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("internal")
      expect(r[:payload][:message]).to include("rpc error")
    end

    it "exposes inner.details through when present" do
      allow(v1).to receive(:get_processes).and_return(
        [422, { "content-type" => "application/json" },
         [JSON.dump(error: { "code" => "validation_failed", "message" => "no good",
                             "details" => ["bad foo"] })]]
      )
      r = dispatcher.call("processes.list", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("validation_failed")
      expect(r[:payload][:details]).to eq(["bad foo"])
    end

    it "non-JSON success body becomes an internal error" do
      allow(v1).to receive(:get_processes).and_return(
        [200, { "content-type" => "application/json" }, ["this is not json"]]
      )
      r = dispatcher.call("processes.list", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("internal")
    end
  end

  describe "FakeRequest accessors" do
    it "returns nil for any get_header request" do
      r = Prouterd::API::FakeRequest.new(params: { "a" => "b" }, body: { "x" => 1 })
      expect(r.params).to eq("a" => "b")
      expect(r.get_header("anything")).to be_nil
      expect(r.content_length).to eq(JSON.dump("x" => 1).bytesize)
      expect(r.request_method).to eq("POST")
      # body returns a StringIO that yields the JSON
      expect(r.body.read).to eq(JSON.dump("x" => 1))
    end

    it "GET method + zero content length when no body" do
      r = Prouterd::API::FakeRequest.new(params: {})
      expect(r.content_length).to eq(0)
      expect(r.request_method).to eq("GET")
    end
  end
end
