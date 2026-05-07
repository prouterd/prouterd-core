require "spec_helper"
require "rack/test"

RSpec.describe "Prouterd::API::App /v1 endpoints" do
  include Rack::Test::Methods

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics) { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }

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
      queue default
       concurrency 4
       timeout 1m
      exit
      interface manual cli
       no shutdown
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
      route interface cli process pipeline
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end

  describe "GET /v1/status" do
    it "is open without admin token" do
      get "/v1/status"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["accepting"]).to be(true)
      expect(body["in_flight"]).to eq(0)
    end
  end

  describe "GET /metrics" do
    it "renders Prometheus text format with uptime + in_flight gauge" do
      metrics.increment(:runs_total, process: "pipeline", status: "success")
      get "/metrics"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to include("text/plain")
      expect(last_response.body).to include("prouterd_uptime_seconds")
      expect(last_response.body).to include("prouterd_in_flight_runs 0")
      expect(last_response.body).to match(/prouterd_runs_total\{.*process="pipeline".*status="success"\} 1/)
    end
  end

  describe "GET /v1/config/running" do
    it "renders the canonical config as text/plain" do
      get "/v1/config/running"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to include("text/plain")
      expect(last_response.body).to include("router demo")
      expect(last_response.body).to include("process pipeline")
    end
  end

  describe "GET /v1/config/commits" do
    it "lists commits with running marker" do
      get "/v1/config/commits"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["data"].length).to eq(1)
      expect(body["meta"]["running"]).to eq(1)
    end
  end

  describe "POST /v1/config/check" do
    it "returns 200 + valid:true for good DSL" do
      post "/v1/config/check", "router x\nexit\nqueue q\n concurrency 1\n timeout 1m\nexit\n"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["valid"]).to be(true)
    end

    it "returns 422 + errors for invalid DSL" do
      post "/v1/config/check", "router x\nexit\nprocess p\nexit\n"
      expect(last_response.status).to eq(422)
      body = JSON.parse(last_response.body)
      expect(body["valid"]).to be(false)
      expect(body["errors"]).not_to be_empty
    end
  end

  describe "POST /v1/config/apply" do
    it "validates and creates a new commit" do
      header "x-author", "alice"
      header "x-commit-message", "applied via api"
      post "/v1/config/apply", <<~PRC
        router demo
        exit
        queue default
         concurrency 1
         timeout 1m
        exit
        interface manual cli
         no shutdown
        exit
        interface docker img1
         image alpine:1
        exit
        process p2
         queue default
         block a
          interface docker img1
         exit
        exit
        route interface cli process p2
        exit
      PRC
      expect(last_response.status).to eq(201)
      body = JSON.parse(last_response.body)
      expect(body["data"]["commit_id"]).to be_a(Integer)
      expect(store.running_commit.id).to eq(body["data"]["commit_id"])
    end
  end

  describe "POST /v1/config/rollback" do
    it "rolls back running pointer" do
      store.commit(parse("router demo\n hostname two\nexit\n"))
      post "/v1/config/rollback", JSON.dump(commit_id: 1), { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      expect(store.running_commit.id).to eq(1)
    end

    it "returns 404 on unknown commit" do
      post "/v1/config/rollback", JSON.dump(commit_id: 9999), { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
    end
  end

  describe "GET /v1/runs replay_of_uid resolution" do
    it "fills replay_of_uid when a run was triggered as a replay of another" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      original = runs_repo.create_run(process_name: "pipeline", input_event: { "x" => 1 })
      replay   = runs_repo.create_run(
        process_name: "pipeline",
        input_event:  { "x" => 1 },
        replay_of_run_id: original.id
      )

      get "/v1/runs"
      data = JSON.parse(last_response.body)["data"]
      replay_row = data.find { |r| r["uid"] == replay.uid }
      original_row = data.find { |r| r["uid"] == original.uid }

      expect(replay_row["replay_of_uid"]).to eq(original.uid)
      expect(original_row["replay_of_uid"]).to be_nil
    end
  end

  describe "GET /v1/processes" do
    it "lists processes" do
      get "/v1/processes"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(1)
      expect(data.first["name"]).to eq("pipeline")
    end
  end

  describe "POST /v1/config/save-boot" do
    it "blesses the running commit as boot and returns it" do
      # Apply once so there's a running pointer to bless.
      post "/v1/config/apply",
           "router demo\nexit\nqueue q\n concurrency 1\n timeout 1m\nexit\n",
           { "CONTENT_TYPE" => "text/plain" }
      expect(last_response.status).to eq(201)

      post "/v1/config/save-boot"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data["commit_id"]).to be_a(Integer)
    end

    it "409s when there is no running config to bless" do
      empty_db    = Prouterd::Storage::DB.open(":memory:")
      empty_store = Prouterd::ControlPlane::ConfigStore.new(empty_db)
      empty_jobs  = Prouterd::Storage::Repositories::Jobs.new(empty_db)
      empty_app   = Prouterd::API::App.new(
        store: empty_store, runner: runner, jobs: empty_jobs,
        in_flight: in_flight, metrics: metrics, admin_token: nil
      )

      env = Rack::MockRequest.new(empty_app).post("/v1/config/save-boot").errors
      response = Rack::MockRequest.new(empty_app).post("/v1/config/save-boot")
      expect(response.status).to eq(409)
      empty_db.close
    end
  end

  describe "GET /v1/artifacts/:id/download" do
    it "streams the file bytes with content-disposition" do
      require "tempfile"
      tmp = Tempfile.new(["art", ".json"])
      tmp.write('{"ok":true}')
      tmp.flush

      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {}, interface_name: "cli")
      step = runs_repo.create_step(run_id: run.id, block_name: "extract")
      runs_repo.add_artifact(
        run_id: run.id, step_id: step.id, block_name: "extract",
        name: "out.json", path: tmp.path, size_bytes: tmp.size,
        content_type: "application/json"
      )
      art = runs_repo.list_artifacts(run.id).first

      get "/v1/artifacts/#{art.id}/download"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["content-type"]).to eq("application/json")
      expect(last_response.headers["content-disposition"]).to include('filename="out.json"')
      expect(last_response.body).to eq('{"ok":true}')
    ensure
      tmp&.close
      tmp&.unlink
    end

    it "404s for unknown artifact id" do
      get "/v1/artifacts/9999/download"
      expect(last_response.status).to eq(404)
    end

    it "410s when the underlying file no longer exists" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {}, interface_name: "cli")
      step = runs_repo.create_step(run_id: run.id, block_name: "extract")
      runs_repo.add_artifact(
        run_id: run.id, step_id: step.id, block_name: "extract",
        name: "ghost.json", path: "/tmp/this-path-does-not-exist-xyz", size_bytes: 5,
        content_type: "application/json"
      )
      art = runs_repo.list_artifacts(run.id).first

      get "/v1/artifacts/#{art.id}/download"
      expect(last_response.status).to eq(410)
    end
  end

  describe "?token= query parameter auth (browser fallback)" do
    let(:app) do
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics, admin_token: "secret"
      )
    end

    it "rejects /v1/processes without any credentials" do
      get "/v1/processes"
      expect(last_response.status).to eq(401)
    end

    it "accepts /v1/processes with the bearer header" do
      get "/v1/processes", {}, { "HTTP_AUTHORIZATION" => "Bearer secret" }
      expect(last_response.status).to eq(200)
    end

    it "accepts /v1/processes with the ?token= query parameter" do
      get "/v1/processes?token=secret"
      expect(last_response.status).to eq(200)
    end

    it "rejects /v1/processes with a wrong ?token= query parameter" do
      get "/v1/processes?token=nope"
      expect(last_response.status).to eq(403)
    end

    it "lets <a download> hit /v1/artifacts/:id/download with ?token=" do
      require "tempfile"
      tmp = Tempfile.new(["art", ".bin"])
      tmp.write("payload")
      tmp.flush

      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs_repo.create_run(process_name: "pipeline", input_event: {}, interface_name: "cli")
      step = runs_repo.create_step(run_id: run.id, block_name: "extract")
      runs_repo.add_artifact(
        run_id: run.id, step_id: step.id, block_name: "extract",
        name: "out.bin", path: tmp.path, size_bytes: tmp.size,
        content_type: "application/octet-stream"
      )
      art = runs_repo.list_artifacts(run.id).first

      get "/v1/artifacts/#{art.id}/download?token=secret"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("payload")
    ensure
      tmp&.close
      tmp&.unlink
    end
  end

  describe "GET /v1/interfaces" do
    it "lists interfaces from running config" do
      get "/v1/interfaces"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(2)
      expect(data.map { |d| d.values_at("name", "type") })
        .to contain_exactly(["cli", "manual"], ["img1", "docker"])
    end

    it "exposes plugin-declared fields under `fields` and the direction" do
      get "/v1/interfaces"
      data = JSON.parse(last_response.body)["data"]

      docker_iface = data.find { |d| d["type"] == "docker" }
      expect(docker_iface["direction"]).to eq("outbound")
      expect(docker_iface["fields"]).to include("image" => "alpine:1")

      manual_iface = data.find { |d| d["type"] == "manual" }
      expect(manual_iface["direction"]).to eq("inbound")
    end
  end

  describe "GET /v1/queues" do
    it "lists queues" do
      get "/v1/queues"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.first).to include("name" => "default", "concurrency" => 4)
    end
  end

  describe "GET /v1/policies" do
    it "lists policies (empty for fixture without policies)" do
      get "/v1/policies"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["data"]).to eq([])
    end

    it "exposes retry_when match conditions when declared" do
      doc_with_policy = parse(<<~PRC)
        router demo
        exit
        policy r3
         retry attempts 3
         retry backoff fixed
         retry initial-delay 1s
         retry when error_type in "timeout","http_status"
         retry when error_type eq "llm_error"
        exit
        interface manual cli
         no shutdown
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         block a
          interface docker img1
         exit
        exit
        route interface cli process p
        exit
      PRC

      store2 = Prouterd::ControlPlane::ConfigStore.new(db)
      store2.commit(doc_with_policy)
      get "/v1/policies"
      data = JSON.parse(last_response.body)["data"]
      policy = data.find { |p| p["name"] == "r3" }
      expect(policy["retry_when"]).to eq([
        { "path" => "error_type", "operator" => "in", "values" => %w[timeout http_status] },
        { "path" => "error_type", "operator" => "eq", "values" => ["llm_error"] }
      ])
    end
  end

  describe "GET /v1/secrets" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        secret WEBHOOK_TOKEN
         source env WEBHOOK_TOKEN
        exit
        secret CLEARBIT_API_KEY
         source env CLEARBIT_API_KEY
        exit
        queue default
         concurrency 1
         timeout 1m
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         queue default
         block enrich
          interface docker img1
          secret CLEARBIT_API_KEY
         exit
        exit
      PRC
    end

    it "returns names + source refs + status, never values" do
      get "/v1/secrets"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      names = data.map { |s| s["name"] }
      expect(names).to include("WEBHOOK_TOKEN", "CLEARBIT_API_KEY")

      clearbit = data.find { |s| s["name"] == "CLEARBIT_API_KEY" }
      expect(clearbit["source_type"]).to eq("env")
      expect(clearbit["source_ref"]).to  eq("CLEARBIT_API_KEY")
      expect(clearbit["used_by"]).to     include("block enrich")
      expect(clearbit["status"]).to      satisfy { |s| %w[present missing].include?(s) }

      # No `value` key, ever — secret values must not cross the wire.
      expect(data).to all(satisfy { |s| !s.key?("value") })
    end
  end

  describe "GET /v1/processes/:name" do
    it "returns detail" do
      get "/v1/processes/pipeline"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data["blocks"].first["name"]).to eq("extract")
    end

    it "exposes block.interface, call_fields, and secret_names" do
      get "/v1/processes/pipeline"
      block = JSON.parse(last_response.body)["data"]["blocks"].first
      expect(block).to include(
        "name"         => "extract",
        "interface"    => { "type" => "docker", "name" => "img1" },
        "secret_names" => []
      )
      expect(block).to have_key("call_fields")
    end

    it "404 unknown" do
      get "/v1/processes/ghost"
      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /v1/processes/:name/trigger" do
    it "enqueues a run, returns run_id with 202" do
      post "/v1/processes/pipeline/trigger",
           JSON.dump(body: { name: "x" }),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
      data = JSON.parse(last_response.body)["data"]
      expect(data["run_id"]).to match(/\Arun_/)

      repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = repo.get_run_by_uid(data["run_id"])
      expect(run.process_name).to eq("pipeline")
    end
  end

  describe "GET /v1/runs and detail/logs/artifacts" do
    let(:run) do
      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      runner.default do |req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "ok\n", stderr: "warn\n",
          output_json: { "ok" => true }, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 5, started_at: nil, finished_at: nil
        )
      end
      orchestrator.trigger(document, "pipeline", input_event: { "body" => "x" }, commit_id: store.running_commit.id)
    end

    it "lists runs" do
      run # create one
      get "/v1/runs"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(1)
      expect(data.first["uid"]).to eq(run.uid)
    end

    it "filters by process and status" do
      run
      get "/v1/runs", { "process" => "pipeline", "status" => "success" }
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(1)

      get "/v1/runs", { "status" => "failed" }
      expect(JSON.parse(last_response.body)["data"]).to be_empty
    end

    it "shows run detail with steps" do
      get "/v1/runs/#{run.uid}"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data["uid"]).to eq(run.uid)
      expect(data["steps"].first["block_name"]).to eq("extract")
    end

    it "lists logs filterable by stream" do
      get "/v1/runs/#{run.uid}/logs", { "stream" => "stdout" }
      data = JSON.parse(last_response.body)["data"]
      expect(data.map { |l| l["stream"] }).to all(eq("stdout"))
    end

    it "404 on unknown run uid" do
      get "/v1/runs/run_deadbeef"
      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /v1/runs/:uid/cancel" do
    it "marks run canceled" do
      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      run = orchestrator.runs.create_run(process_name: "pipeline", input_event: {})
      orchestrator.runs.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))

      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(200)

      refreshed = orchestrator.runs.get_run(run.id)
      expect(refreshed.status).to eq("canceled")
    end

    it "409 when already terminal" do
      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      run = orchestrator.runs.create_run(process_name: "pipeline", input_event: {})
      orchestrator.runs.update_run(run.id, status: "success", finished_at: Time.now.utc.iso8601(3))

      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(409)
    end
  end

  describe "POST /v1/runs/:uid/replay" do
    it "creates a new run referencing the original" do
      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      original = orchestrator.trigger(
        document, "pipeline",
        input_event: { "body" => "x" },
        commit_id: store.running_commit.id
      )

      post "/v1/runs/#{original.uid}/replay"
      expect(last_response.status).to eq(202)
      data = JSON.parse(last_response.body)["data"]
      expect(data["replay_of"]).to eq(original.uid)
    end
  end

  describe "POST /v1/trace" do
    it "renders trace payload for a configured event" do
      post "/v1/trace",
           JSON.dump(event: { "anything" => true }, interface: "cli"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data["process"]).to eq("pipeline")
    end
  end

  describe "admin auth" do
    let(:app) do
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics,
        admin_token: "topsecret"
      )
    end

    it "lets /v1/status through without bearer" do
      get "/v1/status"
      expect(last_response.status).to eq(200)
    end

    it "rejects /v1/processes without bearer" do
      get "/v1/processes"
      expect(last_response.status).to eq(401)
    end

    it "rejects wrong bearer" do
      header "authorization", "Bearer nope"
      get "/v1/processes"
      expect(last_response.status).to eq(403)
    end

    it "accepts right bearer" do
      header "authorization", "Bearer topsecret"
      get "/v1/processes"
      expect(last_response.status).to eq(200)
    end
  end

  describe "graceful shutdown" do
    it "503 on POSTs after stop_accepting; 200 on GET /v1/status" do
      app.stop_accepting

      post "/v1/processes/pipeline/trigger", JSON.dump(body: {}), { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(503)

      get "/v1/status"
      expect(last_response.status).to eq(200)

      get "/v1/processes"
      expect(last_response.status).to eq(200) # GET still works for observers
    end
  end

  describe "webhook method enforcement" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        secret WEBHOOK_TOKEN
         source env WEBHOOK_TOKEN
        exit
        interface webhook leads_in
         path /leads
         method POST
         auth bearer secret WEBHOOK_TOKEN
         no shutdown
        exit
        interface docker img1
         image alpine:1
        exit
        process p
         block a
          interface docker img1
         exit
        exit
        route interface leads_in process p
        exit
      PRC
    end

    before { ENV["WEBHOOK_TOKEN"] = "tok" }
    after { ENV.delete("WEBHOOK_TOKEN") }

    it "405 on GET when method is POST" do
      header "authorization", "Bearer tok"
      get "/i/leads_in"
      expect(last_response.status).to eq(405)
      expect(last_response.headers["allow"]).to eq("POST")
    end

    it "200/202 on POST" do
      header "authorization", "Bearer tok"
      header "content-type", "application/json"
      post "/i/leads_in", "{}"
      expect(last_response.status).to eq(202)
    end
  end
end
