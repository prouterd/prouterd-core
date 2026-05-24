require "spec_helper"
require "rack/test"
require "stringio"

RSpec.describe "Prouterd::API::App body-size enforcement" do
  include Rack::Test::Methods

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics) { Prouterd::API::Metrics.new(in_flight: in_flight) }

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

  before do
    store.commit(parse(<<~PRC))
      router demo
      exit
      interface docker img1
       image x
      exit
      process p
       block a
        interface docker img1
       exit
      exit
    PRC
  end

  it "rejects oversized webhook with 413 + reports limit" do
    huge = "x" * 2_000_000
    header "content-length", huge.bytesize.to_s
    ENV["PROUTERD_MAX_BODY_BYTES"] = "10000"
    post "/i/anything", huge, { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).to eq(413)
    body = JSON.parse(last_response.body)
    expect(body["error"]["code"]).to eq("payload_too_large")
    expect(body["error"]["message"]).to include("too large")
    expect(body["error"]["details"]["limit_bytes"]).to eq(10_000)
  ensure
    ENV.delete("PROUTERD_MAX_BODY_BYTES")
  end

  it "applies a higher cap for /v1/config/apply (DSL files)" do
    body = "router x\nexit\n" + ("# pad\n" * 2000) # ~12KB
    header "content-length", body.bytesize.to_s
    ENV["PROUTERD_MAX_BODY_BYTES"] = "1000"   # tight ingestion cap
    ENV["PROUTERD_MAX_CONFIG_BYTES"] = "1_000_000".tr("_", "")
    post "/v1/config/apply", body, { "CONTENT_TYPE" => "text/plain" }
    expect(last_response.status).not_to eq(413)
  ensure
    ENV.delete("PROUTERD_MAX_BODY_BYTES")
    ENV.delete("PROUTERD_MAX_CONFIG_BYTES")
  end

  it "passes small bodies through" do
    header "content-length", "10"
    post "/i/p", JSON.dump({}), { "CONTENT_TYPE" => "application/json" }
    expect(last_response.status).not_to eq(413)
  end

  it "rejects oversized bodies even when Content-Length is absent" do
    ENV["PROUTERD_MAX_CONFIG_BYTES"] = "10000"
    env = Rack::MockRequest.env_for(
      "/v1/config/check",
      method: "POST",
      input: StringIO.new("x" * 20_000),
      "CONTENT_TYPE" => "text/plain"
    )
    env.delete("CONTENT_LENGTH")

    status, _headers, body = app.call(env)

    expect(status).to eq(413)
    parsed = JSON.parse(body.each.to_a.join)
    expect(parsed["error"]["code"]).to eq("payload_too_large")
    expect(parsed["error"]["details"]["limit_bytes"]).to eq(10_000)
  ensure
    ENV.delete("PROUTERD_MAX_CONFIG_BYTES")
  end
end
