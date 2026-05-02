require "spec_helper"
require "rack/test"

RSpec.describe "Prouterd::API::App /v1 endpoints" do
  include Rack::Test::Methods

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics) { Prouterd::API::Metrics.new(in_flight: in_flight) }

  let(:app) do
    Prouterd::API::App.new(
      store: store, runner: runner,
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
      process pipeline
       queue default
       block extract
        image x
        input event.body
        output result
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
        process p2
         queue default
         block a
          image x
          output r
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

  describe "GET /v1/processes" do
    it "lists processes" do
      get "/v1/processes"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(1)
      expect(data.first["name"]).to eq("pipeline")
    end
  end

  describe "GET /v1/processes/:name" do
    it "returns detail" do
      get "/v1/processes/pipeline"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data["blocks"].first["name"]).to eq("extract")
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
        store: store, runner: runner,
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
        process p
         block a
          image x
          output r
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
