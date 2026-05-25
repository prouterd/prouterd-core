require "spec_helper"
require "rack/test"

# Adds the missing branches in v1.rb: check 200 response shape (line 55),
# process_detail with parallel + merge groups (lines 526/528/531), trace
# edges body (line 721).
RSpec.describe "Prouterd::API::V1 deeper coverage" do
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

  it "POST /v1/config/check returns 200 with warnings array on a valid doc" do
    post "/v1/config/check", read_fixture("minimal.prc"),
         { "CONTENT_TYPE" => "application/x-prouter-dsl" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body).to have_key("warnings")
    expect(body["valid"]).to be(true)
  end

  it "GET /v1/processes/:name renders parallel + merge groups + route matches" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image foo
      exit
      process p
       block start
        interface docker img
       exit
       parallel pj
        block leaf1
         interface docker img
        exit
        block leaf2
         interface docker img
        exit
       exit
       merge join
        from leaf1, leaf2
        strategy all-required
       exit
       block fini
        interface docker img
       exit
       route start pj
       route join fini
        match event.go eq "yes"
       exit
      exit
    PRC
    store.commit(doc)
    get "/v1/processes/p"
    expect(last_response.status).to eq(200)
    payload = JSON.parse(last_response.body)
    data = payload["data"]
    expect(data["parallel_groups"]).not_to be_empty
    expect(data["merge_groups"]).not_to be_empty
    # Find the route to 'fini' and check it has the materialised match
    route = data["routes"].find { |r| r["to"] == "fini" }
    expect(route["matches"]).not_to be_empty
    expect(route["matches"].first["path"]).to eq("event.go")
  end

  it "GET /v1/processes/:name surfaces fan_out + agentic + skip_when block detail" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface llm m
       provider anthropic
       model claude-X
      exit
      interface docker img
       image foo
      exit
      process p
       block scout
        interface docker img
        produces hits.csv
        fan-out from hits into worker
       exit
       block thinker
        interface llm m
        prompt "go"
        agentic on
        allowed-tools none
       exit
       block guarded
        interface docker img
        skip-when event.skip eq "yes"
       exit
      exit
      process worker
       block w
        interface docker img
       exit
      exit
    PRC
    # remove the (invalid) `allowed-tools none` setting back to no tools
    doc.processes.first.block("thinker").allowed_tools.clear
    # tool resolution would fail validation; commit raw via direct
    store.instance_variable_get(:@db).execute("UPDATE config_commits SET id=id") rescue nil
    store.commit(doc) rescue nil
    allow(store).to receive(:load_running).and_return(doc)

    get "/v1/processes/p"
    expect(last_response.status).to eq(200)
    payload = JSON.parse(last_response.body)["data"]
    scout = payload["blocks"].find { |b| b["name"] == "scout" }
    expect(scout["fan_out"]).to be_a(Hash)
    expect(scout["fan_out"]).to include("from" => "hits", "into" => "worker")

    thinker = payload["blocks"].find { |b| b["name"] == "thinker" }
    expect(thinker["agentic"]).to be_a(Hash)

    guarded = payload["blocks"].find { |b| b["name"] == "guarded" }
    expect(guarded["skip_when"]).to include("path" => "event.skip")
  end

  it "GET /v1/secrets surfaces present/missing for env-sourced secrets" do
    ENV["V1_EXTRA_PRESENT"] = "value"
    ENV.delete("V1_EXTRA_MISSING")
    doc = parse(<<~PRC)
      router demo
      exit
      secret PRESENT
       source env V1_EXTRA_PRESENT
      exit
      secret ABSENT
       source env V1_EXTRA_MISSING
      exit
    PRC
    store.commit(doc)
    get "/v1/secrets"
    payload = JSON.parse(last_response.body)["data"]
    by_name = payload.to_h { |s| [s["name"], s] }
    expect(by_name["PRESENT"]["status"]).to eq("present")
    expect(by_name["ABSENT"]["status"]).to eq("missing")
  ensure
    ENV.delete("V1_EXTRA_PRESENT")
  end

  it "GET /v1/interfaces compacts fields with empty-string values" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image foo
       user ""
      exit
    PRC
    store.commit(doc)
    get "/v1/interfaces"
    iface = JSON.parse(last_response.body)["data"].first
    expect(iface["fields"]).to have_key("image")
    expect(iface["fields"]).not_to have_key("user")
  end

  it "GET /v1/config/commits returns meta with nil running/startup when no commits exist" do
    get "/v1/config/commits"
    payload = JSON.parse(last_response.body)
    expect(payload["meta"]).to eq("running" => nil, "startup" => nil)
  end

  it "GET /v1/config/commits surfaces startup_commit.id after write_memory" do
    store.commit(parse("router demo\nexit\n"))
    store.write_memory
    get "/v1/config/commits"
    meta = JSON.parse(last_response.body)["meta"]
    expect(meta["startup"]).to be_a(Integer)
  end

  it "GET /v1/mcp returns no_pool state when @app.mcp_pool is nil" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface mcp local
       server bin "true"
      exit
    PRC
    store.commit(doc)
    # The default v1_more_extra_spec App is built without mcp_pool, so
    # this hits the `no_pool` ternary branch.
    get "/v1/mcp"
    entries = JSON.parse(last_response.body)["data"]
    expect(entries.first["state"]).to eq("no_pool")
  end

  it "POST /v1/trace serializes edge.matches in trace_to_payload" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img
       image foo
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
        match event.go eq "yes"
       exit
      exit
      route interface cli process p
      exit
    PRC
    store.commit(doc)
    post "/v1/trace", JSON.dump(interface: "cli", event: { "go" => "yes" }),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    edge = body["data"]["edges"].find { |e| e["from"] == "a" && e["to"] == "b" }
    expect(edge).not_to be_nil
    expect(edge["matches"]).not_to be_empty
    expect(edge["matches"].first["path"]).to eq("event.go")
  end
end

RSpec.describe "API::V1 POST /v1/config/check warnings rendering" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "renders the warnings array entries when validator produces warnings" do
    # Stub validator result to inject a warning so the .map body fires.
    fake_result = double(valid?: true, errors: [],
                         warnings: [double(line: 1, message: "synthetic warning")])
    allow(Prouterd::Config::Validator).to receive(:validate).and_return(fake_result)
    post "/v1/config/check", "router demo\nexit\n",
         { "CONTENT_TYPE" => "application/x-prouter-dsl" }
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["warnings"]).to include("line" => 1, "message" => "synthetic warning")
  end
end

RSpec.describe "API::V1 /v1/mcp state ternary 'unknown' when @app has pool but iface not in health" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  let(:partial_pool) do
    Object.new.tap do |p|
      def p.health; { "alpha" => { state: :ready, tools: [], last_error: nil } }; end
    end
  end

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil,
      mcp_pool: partial_pool
    )
  end

  it "shows 'unknown' for an iface that exists in config but not in the pool's health snapshot" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface mcp alpha
       server bin "/bin/sh"
      exit
      interface mcp beta
       server bin "/bin/sh"
      exit
    PRC
    store.commit(doc)
    get "/v1/mcp"
    by_name = JSON.parse(last_response.body)["data"].to_h { |x| [x["name"], x] }
    expect(by_name["alpha"]["state"]).to eq("ready")
    expect(by_name["beta"]["state"]).to eq("unknown")
  end
end

RSpec.describe "API::V1 GET /v1/mcp falls back to {} health when mcp_pool.health is nil" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  let(:nil_health_pool) do
    Object.new.tap do |p|
      def p.health; nil; end
    end
  end

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil,
      mcp_pool: nil_health_pool
    )
  end

  it "treats pool with nil health as empty → state: 'unknown'" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface mcp m
       server bin "/bin/sh"
      exit
    PRC
    store.commit(doc)
    get "/v1/mcp"
    data = JSON.parse(last_response.body)["data"]
    expect(data.first["state"]).to eq("unknown")
  end
end

RSpec.describe "API::V1 GET /v1/mcp state branches" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  let(:fake_pool) do
    Object.new.tap do |p|
      def p.health
        {
          "iface1" => { state: :ready, tools: [{ "name" => "t1" }], last_error: nil },
          "iface2" => { state: :degraded, tools: [], last_error: "boom" }
        }
      end
    end
  end

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil,
      mcp_pool: fake_pool
    )
  end

  it "renders the state from health for each iface (covers h-truthy ternary)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface mcp iface1
       server bin "/bin/sh"
      exit
      interface mcp iface2
       server bin "/bin/sh"
      exit
      interface mcp iface3
       server bin "/bin/sh"
      exit
    PRC
    store.commit(doc)
    get "/v1/mcp"
    data = JSON.parse(last_response.body)["data"]
    by_name = data.to_h { |x| [x["name"], x] }
    expect(by_name["iface1"]["state"]).to eq("ready")
    expect(by_name["iface2"]["state"]).to eq("degraded")
    expect(by_name["iface2"]["last_error"]).to eq("boom")
    # iface3 not in health → "unknown" because mcp_pool exists
    expect(by_name["iface3"]["state"]).to eq("unknown")
  end
end

RSpec.describe "API::V1 replay from_block payload without context.event" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "falls back to original.input_event_json when payload context has no event" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p",
                          input_event: { "from" => "original" },
                          process_config_commit_id: store.running_commit.id)
    step = runs.create_step(run_id: run.id, block_name: "hello")
    # payload.context has no 'event' key — falls back through ||
    runs.update_step(step.id, status: "success",
                              input_json: JSON.dump("context" => { "other" => "x" }))
    post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
  end

  it "falls back to {} when original.input_event_json is also nil" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: {},
                          process_config_commit_id: store.running_commit.id)
    db.execute("UPDATE runs SET input_event_json = NULL WHERE id = ?", [run.id])
    step = runs.create_step(run_id: run.id, block_name: "hello")
    runs.update_step(step.id, status: "success",
                              input_json: JSON.dump("context" => {}))
    post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
  end
end

RSpec.describe "API::V1 interface_summary respond_to?(:empty?) false branch" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "keeps a non-string, non-Hash field value (the else of respond_to?(:empty?))" do
    v1 = Prouterd::API::V1.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
      in_flight: nil, metrics: nil,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      app: nil
    )
    iface = Prouterd::Config::AST::Interface.new(type: "docker", name: "i", line: 1)
    iface.type_fields = { "image" => "x", "memory" => 12345 }
    summary = v1.send(:interface_summary, iface)
    # 12345 doesn't respond_to?(:empty?) → not dropped
    expect(summary[:fields]["memory"]).to eq(12345)
  end
end

RSpec.describe "API::V1 GET /v1/runs/:uid/logs filtered by stream" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "filters log rows by ?stream= parameter" do
    doc = parse("router demo\nexit\n")
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: {})
    runs.append_log(run_id: run.id, stream: "stdout", content: "out-line")
    runs.append_log(run_id: run.id, stream: "stderr", content: "err-line")
    get "/v1/runs/#{run.uid}/logs", { "stream" => "stdout" }
    payload = JSON.parse(last_response.body)["data"]
    streams = payload.map { |l| l["stream"] }
    expect(streams).to all(eq("stdout"))
  end
end

RSpec.describe "API::V1 post_run_replay use_current_config conflict" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "returns 409 when use_current_config is true but no running pointer exists" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    run = Prouterd::Storage::Repositories::Runs.new(db).create_run(
      process_name: "p", input_event: {}, process_config_commit_id: store.running_commit.id
    )
    # Strip the running pointer so use_current_config has nothing to bind to
    db.execute("DELETE FROM config_pointers WHERE name = 'running'")
    post "/v1/runs/#{run.uid}/replay", JSON.dump(use_current_config: true),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(409)
  end
end

RSpec.describe "API::V1 interface_summary empty-string value drop" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "drops fields whose value is an empty String/Array (respond_to :empty? && empty?)" do
    v1 = Prouterd::API::V1.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
      in_flight: nil, metrics: nil,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      app: nil
    )
    iface = Prouterd::Config::AST::Interface.new(type: "llm", name: "l", line: 1)
    iface.type_fields = {
      "provider" => "claude_cli",
      "model"    => "m",
      "env"      => {},          # respond_to?(:empty?) && empty?
      "env-forward" => [],       # ditto
      "secret"   => [],          # ditto
    }
    summary = v1.send(:interface_summary, iface)
    expect(summary[:fields]).not_to have_key("env")
    expect(summary[:fields]).not_to have_key("env-forward")
    expect(summary[:fields]).not_to have_key("secret")
    expect(summary[:fields]).to include("provider" => "claude_cli", "model" => "m")
  end
end

RSpec.describe "API::V1 replay: payload without 'context' key" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "uses original.input_event_json when input_json lacks 'context' (no &.dig short-circuit)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: { "from" => "orig" },
                          process_config_commit_id: store.running_commit.id)
    step = runs.create_step(run_id: run.id, block_name: "hello")
    # input_json with NO 'context' key
    runs.update_step(step.id, status: "success", input_json: JSON.dump("other" => "x"))
    post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
  end
end

RSpec.describe "API::V1 post_run_replay original.input_event_json nil" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "feeds {} when no from_block AND original.input_event_json is nil (else of ternary on L341)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: {},
                          process_config_commit_id: store.running_commit.id)
    db.execute("UPDATE runs SET input_event_json = NULL WHERE id = ?", [run.id])
    post "/v1/runs/#{run.uid}/replay", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
  end
end

RSpec.describe "API::V1 post_run_replay use_current_config success" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "binds to the current running commit when use_current_config=true" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    run = Prouterd::Storage::Repositories::Runs.new(db).create_run(
      process_name: "p", input_event: {}, process_config_commit_id: store.running_commit.id
    )
    post "/v1/runs/#{run.uid}/replay", JSON.dump(use_current_config: true),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
    expect(JSON.parse(last_response.body)["data"]["use_current_config"]).to be(true)
  end
end

RSpec.describe "API::V1 post_process_trigger" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
  end

  it "passes commit_id: nil and survives @metrics nil on /v1/processes/:name/trigger" do
    store.commit(document)
    allow(store).to receive(:running_commit).and_return(nil)
    post "/v1/processes/p/trigger", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
    latest = Prouterd::Storage::Repositories::Runs.new(db).list_runs(limit: 1).first
    expect(latest.process_config_commit_id).to be_nil
  end
end

RSpec.describe "API::V1 build_orchestrator without app" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "constructs an orchestrator without system_url / mcp_pool when app is nil" do
    v1 = Prouterd::API::V1.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
      in_flight: nil, metrics: nil,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      app: nil
    )
    orch = v1.send(:build_orchestrator)
    expect(orch).to be_a(Prouterd::Runtime::Orchestrator)
  end
end

RSpec.describe "API::V1 interface_summary with unknown iface type" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "returns a summary with direction: nil when plugin lookup fails" do
    v1 = Prouterd::API::V1.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
      in_flight: nil, metrics: nil,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      app: nil
    )
    iface = Prouterd::Config::AST::Interface.new(type: "phantom-type", name: "x", line: 1)
    summary = v1.send(:interface_summary, iface)
    expect(summary[:name]).to eq("x")
    expect(summary[:type]).to eq("phantom-type")
    expect(summary).not_to have_key(:direction) # compact drops nil
  end
end

RSpec.describe "API::V1 post_run_replay from_block with context.event payload" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "feeds payload['context']['event'] into the new run when present" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: { "from" => "outer" },
                          process_config_commit_id: store.running_commit.id)
    step = runs.create_step(run_id: run.id, block_name: "hello")
    runs.update_step(step.id, status: "success",
                              input_json: JSON.dump("context" => { "event" => { "from" => "inner" } }))

    post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
         { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(202)
  end
end

RSpec.describe "API::V1 post_run_cancel when docker-api is unavailable" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: Prouterd::Runtime::InFlightRegistry.new,
      metrics: nil, admin_token: nil
    )
  end

  it "does not iterate container_ids_for when DockerRunner.docker_available? is false" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block a
        interface docker img
       exit
      exit
    PRC
    store.commit(doc)
    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(process_name: "p", input_event: {})
    allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(false)
    post "/v1/runs/#{run.uid}/cancel"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["data"]["killed_containers"]).to eq([])
  end
end

RSpec.describe "API::V1 interface_summary drops empty-string field values" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "excludes a field whose value is an empty string" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img
       image x
       user ""
      exit
    PRC
    store.commit(doc)
    get "/v1/interfaces"
    iface = JSON.parse(last_response.body)["data"].first
    expect(iface["fields"]).not_to have_key("user")
  end
end

RSpec.describe "API::V1 publish_config_changed with no running_commit" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "publishes running_commit: nil to the events bus" do
    events = Prouterd::Events.new
    payloads = []
    events.subscribe(:config_changed) { |_t, p| payloads << p }
    v1 = Prouterd::API::V1.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
      in_flight: nil, metrics: nil,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      app: nil, events: events
    )
    v1.send(:publish_config_changed, "commit")
    expect(payloads.first).to include(running_commit: nil)
  end
end

RSpec.describe "API::V1 GET /v1/mcp state ternary" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  let(:doc) do
    parse(<<~PRC)
      router demo
      exit
      interface mcp known
       server bin "true"
      exit
      interface mcp unknown
       server bin "true"
      exit
    PRC
  end

  let(:fake_app) do
    Object.new.tap do |o|
      pool = Object.new
      def pool.health
        {
          "known" => { state: :ready, tools: [{ "name" => "t" }], last_error: nil }
        }
      end
      o.define_singleton_method(:mcp_pool) { pool }
      o.define_singleton_method(:system_url) { nil }
    end
  end

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil,
      mcp_pool: fake_app.mcp_pool
    )
  end

  it "returns :ready state for an iface in health and 'unknown' for one not in health" do
    store.commit(doc)
    get "/v1/mcp"
    payload = JSON.parse(last_response.body)["data"]
    by_name = payload.to_h { |x| [x["name"], x] }
    expect(by_name["known"]["state"]).to eq("ready")
    expect(by_name["unknown"]["state"]).to eq("unknown")
  end
end

RSpec.describe "API::V1 trigger 404 for unknown process" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
    )
  end

  it "returns 404 for POST /v1/processes/<unknown>/trigger" do
    store.commit(parse("router demo\nexit\n"))
    post "/v1/processes/ghost/trigger", "{}", { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
  end
end

RSpec.describe "API::V1 GET /v1/mcp with @app.mcp_pool nil" do
  include Rack::Test::Methods
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  def app
    Prouterd::API::App.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      in_flight: nil, metrics: nil, admin_token: nil
      # no mcp_pool
    )
  end

  it "reports state: no_pool for each mcp iface" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface mcp local
       server bin "true"
      exit
    PRC
    store.commit(doc)
    get "/v1/mcp"
    entries = JSON.parse(last_response.body)["data"]
    expect(entries.first["state"]).to eq("no_pool")
  end
end
