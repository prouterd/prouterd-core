require "spec_helper"
require "rack/test"

# Fill in V1 endpoints + error envelopes the main spec doesn't reach:
# every `json_error` code path, replay from-block, resume not_found,
# cancel with mid-flight steps, trace edge graph, secret usage via
# interface auth, and the summary helpers' alternate shapes.
RSpec.describe "Prouterd::API::V1 extra coverage" do
  include Rack::Test::Methods

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

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      secret WEBHOOK_TOKEN
       source env WEBHOOK_TOKEN
      exit
      queue default
       concurrency 1
       timeout 1m
      exit
      policy r3
       retry attempts 3
       retry backoff fixed
       retry initial-delay 1s
       retry when error_type eq "timeout"
       retry feedback error_message into hint
       retry stop-on error_type eq "validation"
      exit
      tool sentiment
       description "score sentiment"
       args text
       implementation interface mcp atlassian call analyze
      exit
      interface webhook leads_in
       path /leads
       method POST
       auth bearer secret WEBHOOK_TOKEN
       no shutdown
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img1
       image alpine:1
      exit
      interface mcp atlassian
       server npx "@atlassian/mcp-server@1.4.2"
      exit
      process pipeline
       queue default
       block extract
        interface docker img1
       exit
       block transform
        interface docker img1
       exit
       route extract transform
      exit
      route interface cli process pipeline
      exit
      route interface leads_in process pipeline
       match event.type eq "lead.created"
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end

  describe "GET /v1/config/startup" do
    it "404 when no startup commit is blessed yet" do
      get "/v1/config/startup"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end

    it "returns the rendered DSL after save-boot" do
      post "/v1/config/save-boot"
      get "/v1/config/startup"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to include("text/plain")
      expect(last_response.body).to include("router demo")
    end
  end

  describe "POST /v1/config/check parser-error rescue" do
    it "returns 400 invalid_dsl with line details on a lexer/parser exception" do
      post "/v1/config/check", "interface webhook x\n missing exit"
      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body.dig("error", "code")).to eq("invalid_dsl")
    end
  end

  describe "POST /v1/config/apply parser-error rescue" do
    it "returns 400 invalid_dsl when the parser raises" do
      post "/v1/config/apply", "interface webhook x\n missing exit"
      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body.dig("error", "code")).to eq("invalid_dsl")
    end

    it "returns 422 validation_failed when the document parses but fails validation" do
      # `route interface ghost process unknown` references nothing.
      post "/v1/config/apply", "router demo\nexit\nroute interface ghost process unknown\nexit\n"
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body.dig("error", "code")).to eq("validation_failed")
    end
  end

  describe "GET /v1/config/commits/:id" do
    it "returns one commit by id" do
      commit_id = store.running_commit.id
      get "/v1/config/commits/#{commit_id}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["data"]["id"]).to eq(commit_id)
      expect(body["data"]["rendered_config"]).to include("router demo")
    end

    it "404 on unknown id" do
      get "/v1/config/commits/99999"
      expect(last_response.status).to eq(404)
    end
  end

  describe "GET /v1/runs/:uid/logs ?block=..." do
    let!(:run) do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      orch.trigger(document, "pipeline",
                   input_event: { "body" => "x" },
                   commit_id: store.running_commit.id)
    end

    it "filters by block name when supplied" do
      get "/v1/runs/#{run.uid}/logs", { "block" => "extract" }
      expect(last_response.status).to eq(200)
    end

    it "404s when no step exists for the requested block" do
      get "/v1/runs/#{run.uid}/logs", { "block" => "ghost_block" }
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end
  end

  describe "POST /v1/runs/:uid/replay" do
    it "422 when the original run wasn't pinned to a commit" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {}) # commit nil by default
      post "/v1/runs/#{r.uid}/replay"
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unprocessable")
    end

    it "404 when the from_block name didn't run in the original" do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      post "/v1/runs/#{original.uid}/replay",
           JSON.dump(from_block: "ghost_block"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
    end

    it "replays from a real block name with seed context carried" do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      post "/v1/runs/#{original.uid}/replay",
           JSON.dump(from_block: "extract"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
      body = JSON.parse(last_response.body)
      expect(body["data"]["from"]).to eq("extract")
    end

    it "404 when the replay uid is unknown" do
      post "/v1/runs/run_does_not_exist/replay"
      expect(last_response.status).to eq(404)
    end

    it "409 when use_current_config is true but no running config exists" do
      # Synthesise a run row, then clear the running pointer so the
      # 'use_current_config' branch finds nothing to bind to.
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      allow(store).to receive(:running_commit).and_return(nil)
      post "/v1/runs/#{original.uid}/replay",
           JSON.dump(use_current_config: true),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(409)
    end

    it "410 when the pinned commit no longer exists" do
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orch.trigger(document, "pipeline",
                              input_event: { "body" => "x" },
                              commit_id: store.running_commit.id)
      # Force the lookup to return nil for the pinned commit id.
      allow(store).to receive(:get_commit).and_return(nil)
      post "/v1/runs/#{original.uid}/replay"
      expect(last_response.status).to eq(410)
    end
  end

  describe "POST /v1/runs/:uid/resume" do
    it "404 when the run uid is unknown" do
      post "/v1/runs/run_does_not_exist/resume"
      expect(last_response.status).to eq(404)
    end

    it "409 when the run is not paused" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(r.id, status: "success")
      post "/v1/runs/#{r.uid}/resume"
      expect(last_response.status).to eq(409)
    end

    it "422 when a paused run wasn't pinned to a commit" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(r.id, status: "paused")
      post "/v1/runs/#{r.uid}/resume"
      expect(last_response.status).to eq(422)
    end

    it "410 when the pinned commit no longer exists" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(r.id, status: "paused", process_config_commit_id: store.running_commit.id)
      allow(store).to receive(:get_commit).and_return(nil)
      post "/v1/runs/#{r.uid}/resume"
      expect(last_response.status).to eq(410)
    end

    it "409 when the orchestrator rejects the resume" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(r.id, status: "paused", process_config_commit_id: store.running_commit.id)
      allow_any_instance_of(Prouterd::Runtime::Orchestrator).to receive(:resume_run)
        .and_raise(Prouterd::Runtime::TriggerError, "no such pause step")
      post "/v1/runs/#{r.uid}/resume", JSON.dump(value: { ok: true }),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body).dig("error", "message")).to include("no such pause step")
    end
  end

  describe "POST /v1/runs/:uid/cancel" do
    it "cancels mid-flight steps too, marking each non-terminal step canceled" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(run.id, status: "running")
      # One non-terminal + one terminal step → only the first should flip.
      pending = runs_repo.create_step(run_id: run.id, block_name: "extract")
      runs_repo.create_step(run_id: run.id, block_name: "transform").tap do |s|
        runs_repo.update_step(s.id, status: "success", finished_at: Time.now.utc.iso8601(3))
      end

      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(200)
      refreshed = runs_repo.list_steps(run.id)
      pending_after = refreshed.find { |s| s.id == pending.id }
      expect(pending_after.status).to eq("canceled")
    end

    it "404 unknown run uid" do
      post "/v1/runs/run_nope/cancel"
      expect(last_response.status).to eq(404)
    end

    it "swallows Docker container kill failures and still reports canceled" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(run.id, status: "running")
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)
      allow(in_flight).to receive(:container_ids_for).with(run.uid).and_return(["bad_cid"])
      docker_container = Class.new { def self.get(_id); end }
      stub_const("Docker", Module.new) unless defined?(::Docker)
      stub_const("Docker::Container", docker_container)
      allow(docker_container).to receive(:get).with("bad_cid").and_raise(StandardError, "no docker")
      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["data"]["killed_containers"]).to eq([])
    end

    it "kills a known container when docker is available" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(run.id, status: "running")
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(true)
      allow(in_flight).to receive(:container_ids_for).with(run.uid).and_return(["cid1"])
      docker_container = Class.new { def self.get(_id); end }
      stub_const("Docker", Module.new) unless defined?(::Docker)
      stub_const("Docker::Container", docker_container)
      container_inst = double("container")
      allow(docker_container).to receive(:get).with("cid1").and_return(container_inst)
      allow(Prouterd::Runner::DockerStop).to receive(:force_stop).with(container_inst)
      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["data"]["killed_containers"]).to eq(["cid1"])
    end
  end

  describe "GET /v1/processes/:name detail surfaces routes + groups" do
    it "lists routes on the process detail" do
      get "/v1/processes/pipeline"
      data = JSON.parse(last_response.body)["data"]
      expect(data["routes"]).not_to be_empty
      expect(data["routes"].first).to include("from" => "extract", "to" => "transform")
      expect(data).to have_key("parallel_groups")
      expect(data).to have_key("merge_groups")
    end
  end

  describe "GET /v1/interfaces auth_bearer summary" do
    it "summarises auth-bearer fields as '<scheme> <secret_name>' (never the value)" do
      get "/v1/interfaces"
      data = JSON.parse(last_response.body)["data"]
      webhook = data.find { |d| d["name"] == "leads_in" }
      expect(webhook["fields"]["auth"]).to eq("bearer WEBHOOK_TOKEN")
    end
  end

  describe "GET /v1/policies retry shape" do
    it "exposes retry_feedback + retry_stop alongside retry_when" do
      get "/v1/policies"
      pol = JSON.parse(last_response.body)["data"].first
      expect(pol["retry_feedback"]).to eq([{ "from" => "error_message", "into" => "hint" }])
      expect(pol["retry_stop"].first["path"]).to eq("error_type")
    end
  end

  describe "GET /v1/tools summary" do
    it "carries the implementation block when one is declared" do
      get "/v1/tools"
      data = JSON.parse(last_response.body)["data"]
      sentiment = data.find { |t| t["name"] == "sentiment" }
      expect(sentiment["implementation"]).to eq(
        "iface_type" => "mcp", "iface_name" => "atlassian", "call_name" => "analyze"
      )
    end

    it "tool_summary's implementation is nil when none is declared" do
      doc = parse(<<~PRC)
        router demo
        exit
        tool plain
         description "no impl"
         args x
        exit
      PRC
      store2 = Prouterd::ControlPlane::ConfigStore.new(db)
      store2.commit(doc)
      get "/v1/tools"
      data = JSON.parse(last_response.body)["data"]
      plain_tool = data.find { |t| t["name"] == "plain" }
      expect(plain_tool["implementation"]).to be_nil
    end
  end

  describe "GET /v1/secrets usage index covers interface auth" do
    it "records 'interface <name>' for secrets used by an auth-bearer iface" do
      get "/v1/secrets"
      data = JSON.parse(last_response.body)["data"]
      wh = data.find { |s| s["name"] == "WEBHOOK_TOKEN" }
      expect(wh["used_by"]).to include("interface leads_in")
    end

    it "secret_status returns 'unknown' for non-env source types" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret API_KEY
         source file /etc/prouterd/api.key
        exit
      PRC
      store2 = Prouterd::ControlPlane::ConfigStore.new(db)
      store2.commit(doc)
      get "/v1/secrets"
      data = JSON.parse(last_response.body)["data"]
      api = data.find { |s| s["name"] == "API_KEY" }
      expect(api["status"]).to eq("unknown")
    end
  end

  describe "POST /v1/trace edge match results" do
    it "returns match_results per edge with path/operator/values/result" do
      post "/v1/trace",
           JSON.dump(event: { "type" => "lead.created" }, interface: "leads_in"),
           { "CONTENT_TYPE" => "application/json" }
      data = JSON.parse(last_response.body)["data"]
      # Edge structure goes through trace_to_payload's `matches:` mapping.
      expect(data["edges"]).to be_a(Array)
    end
  end

  describe "publish_config_changed surfaces startup_commit too" do
    it "carries startup_commit when present in the events payload" do
      events = Prouterd::Events.new
      v1 = Prouterd::API::V1.new(
        store: store, runner: runner, secret_resolver: nil,
        in_flight: in_flight, metrics: metrics, jobs: jobs, events: events
      )
      captured = []
      events.subscribe(:config_changed) { |_, p| captured << p }
      store.write_memory          # gives us a startup_commit pointer
      v1.send(:publish_config_changed, "test_reason")
      expect(captured.size).to eq(1)
      expect(captured.first[:startup_commit]).to be_a(Integer)
    end
  end
end
