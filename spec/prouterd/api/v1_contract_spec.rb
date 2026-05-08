require "spec_helper"
require "rack/test"

# Phase 36a — /v1 envelope freeze.
#
# Each example asserts the EXACT shape (key set + value type) of one
# endpoint's payload. Future drift fails this spec immediately. Adding
# a key is allowed by writing the spec to expect it; removing or
# renaming a key is intentionally disruptive.
#
# We don't do Accept-header negotiation or /v2; user decision in Phase
# 32: breaking changes happen in /v1, no legacy fallbacks.
RSpec.describe "Phase 36a /v1 contract freeze" do
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
      secret API_TOKEN
       source env API_TOKEN
      exit
      policy r3
       retry attempts 3
       retry backoff exponential
       retry initial-delay 1s
       retry when error_type in "timeout","http_status"
      exit
      queue default
       concurrency 4
       timeout 1m
      exit
      interface webhook leads_in
       path /leads
       method PUT
       no shutdown
      exit
      interface manual cli
       no shutdown
      exit
      interface http jira
       base-url https://example.test
      exit
      interface shell host
      exit
      process pipeline
       queue default
       block extract
        interface shell host
        exec "true"
        secret API_TOKEN
       exit
      exit
      route interface cli process pipeline
       match event.type eq "lead.created"
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end

  def data
    JSON.parse(last_response.body)["data"]
  end

  describe "GET /v1/status" do
    it "exact key set" do
      get "/v1/status"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect_keys(body,
                  version: String, router: String,
                  hostname: NilClass,
                  running_commit: Integer, startup_commit: NilClass,
                  interfaces: Integer, processes: Integer,
                  in_flight: Integer, queued: Integer, accepting: TrueClass)
    end
  end

  describe "GET /v1/processes/:name" do
    it "exact key set incl. interface + call_fields + secret_names" do
      get "/v1/processes/pipeline"
      expect(last_response.status).to eq(200)

      expect_keys(data,
                  name: "pipeline", description: NilClass, queue: "default",
                  shutdown: FalseClass, thread_id_template: NilClass,
                  blocks: Array, routes: Array, parallel_groups: Array)

      block = data["blocks"].first
      expect_keys(block,
                  name: "extract",
                  interface: { "type" => "shell", "name" => "host" },
                  call_fields: Hash, timeout_ms: NilClass,
                  retry_policy: NilClass, contract: NilClass,
                  secret_names: ["API_TOKEN"], shutdown: FalseClass,
                  skip_when: NilClass, vars: Hash, fan_out: NilClass,
                  agentic: NilClass, pause_reason: NilClass, barrier: NilClass,
                  max_cost_usd: NilClass)
    end
  end

  describe "GET /v1/interfaces" do
    it "exposes plugin-driven fields hash + direction" do
      get "/v1/interfaces"
      ifaces = JSON.parse(last_response.body)["data"]
      sample = ifaces.find { |i| i["name"] == "leads_in" }
      expect_keys(sample,
                  name: "leads_in", type: "webhook",
                  direction: "inbound", shutdown: FalseClass,
                  fields: a_hash_including("path" => "/leads", "method" => "PUT"))
    end
  end

  describe "GET /v1/policies" do
    it "policy_summary carries retry_when array" do
      get "/v1/policies"
      policy = JSON.parse(last_response.body)["data"].first
      expect_keys(policy,
                  name: "r3", retry_attempts: 3,
                  retry_backoff: "exponential",
                  retry_initial_delay_ms: 1000,
                  retry_max_delay_ms: NilClass,
                  retry_when: a_kind_of(Array),
                  retry_feedback: a_kind_of(Array),
                  retry_stop: a_kind_of(Array),
                  timeout_ms: NilClass)
      expect(policy["retry_when"].first).to include(
        "path" => "error_type",
        "operator" => "in",
        "values" => %w[timeout http_status]
      )
    end
  end

  describe "GET /v1/queues" do
    it "exact key set" do
      get "/v1/queues"
      queue = JSON.parse(last_response.body)["data"].first
      expect_keys(queue, name: "default", concurrency: 4, timeout_ms: 60_000)
    end
  end

  describe "GET /v1/secrets" do
    it "exact key set, no value column" do
      get "/v1/secrets"
      secret = JSON.parse(last_response.body)["data"].first
      expect_keys(secret,
                  name: "API_TOKEN", source_type: "env",
                  source_ref: "API_TOKEN",
                  used_by: a_kind_of(Array), status: a_kind_of(String))
    end
  end

  describe "GET /v1/runs (list)" do
    it "exact key set per run summary" do
      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      orchestrator.trigger(document, "pipeline", input_event: {},
                                                 commit_id: store.running_commit.id)

      get "/v1/runs"
      summary = JSON.parse(last_response.body)["data"].first
      expect_keys(summary,
                  uid: a_string_matching(/\Arun_/),
                  process_name: "pipeline",
                  interface_name: NilClass,
                  status: "success",
                  commit_id: a_kind_of(Integer),
                  replay_of_uid: NilClass,
                  thread_id: NilClass,
                  tokens_in: a_kind_of(Integer),
                  tokens_out: a_kind_of(Integer),
                  cost_usd: a_kind_of(Numeric),
                  duration_ms: a_kind_of(Integer),
                  started_at: a_kind_of(String),
                  finished_at: a_kind_of(String),
                  created_at: a_kind_of(String),
                  error_summary: NilClass)
    end
  end

  # ----- error envelope freeze -----
  #
  # Every 4xx/5xx response body is `{"error": {"code": "<stable>",
  # "message": "<human>", "details"?: <any>}}`. `code` is the
  # contract-stable identifier clients can branch on; `message` is for
  # humans; `details` is optional and shape-flexible.
  #
  # If a future change loses `code`, surfaces strings instead of
  # objects, or adds a sibling key alongside `error` — these specs
  # fail loud. Add new endpoints by adding new `it` blocks with the
  # right code + status; never reshape existing entries without a /v1
  # break note in CHANGELOG.
  describe "error envelope" do
    def error_body
      JSON.parse(last_response.body)["error"]
    end

    it "404 → not_found on unknown process" do
      get "/v1/processes/no-such-process"
      expect(last_response.status).to eq(404)
      expect_keys(error_body,
                  code: "not_found",
                  message: a_string_matching(/no such process/))
    end

    it "404 → not_found on unknown run" do
      get "/v1/runs/run_does_not_exist"
      expect(last_response.status).to eq(404)
      expect_keys(error_body, code: "not_found", message: a_kind_of(String))
    end

    it "400 → invalid_dsl with details.line on parse failure" do
      post "/v1/config/check", "router demo\n  bogus_directive\nexit\n",
           { "CONTENT_TYPE" => "application/octet-stream" }
      expect(last_response.status).to eq(400)
      expect_keys(error_body,
                  code: "invalid_dsl",
                  message: a_kind_of(String),
                  details: a_hash_including("line"))
    end

    it "422 → validation_failed with details array on validator errors" do
      # Process references an interface that wasn't declared.
      # Parses fine, fails validation.
      bad = <<~PRC
        router demo
        exit
        process p
         block b
          interface shell undefined_iface
          exec "true"
         exit
        exit
      PRC
      post "/v1/config/apply", bad, { "CONTENT_TYPE" => "application/octet-stream" }
      expect(last_response.status).to eq(422)
      expect_keys(error_body,
                  code: "validation_failed",
                  message: a_kind_of(String),
                  details: a_kind_of(Array))
    end

    it "400 → bad_json on rollback with non-JSON body" do
      post "/v1/config/rollback", "not json", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(400)
      expect_keys(error_body, code: "bad_json", message: a_kind_of(String))
    end

    it "400 → invalid_argument on rollback with missing commit_id" do
      post "/v1/config/rollback", JSON.dump(other: 1),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(400)
      expect_keys(error_body,
                  code: "invalid_argument",
                  message: a_kind_of(String))
    end

    it "404 → not_found on the daemon's catch-all /v1 route" do
      get "/v1/no/such/path"
      expect(last_response.status).to eq(404)
      expect_keys(error_body, code: "not_found", message: a_kind_of(String))
    end

    it "401 → unauthorized when admin_token is set but not provided" do
      tokened_app = Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics, admin_token: "secret"
      )
      tokened_session = Rack::Test::Session.new(Rack::MockSession.new(tokened_app))
      tokened_session.get "/v1/processes"
      body = JSON.parse(tokened_session.last_response.body)["error"]
      expect(tokened_session.last_response.status).to eq(401)
      expect_keys(body, code: "unauthorized", message: a_kind_of(String))
    end
  end
end
