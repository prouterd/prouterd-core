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
