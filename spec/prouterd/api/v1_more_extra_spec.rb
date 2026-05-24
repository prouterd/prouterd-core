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
