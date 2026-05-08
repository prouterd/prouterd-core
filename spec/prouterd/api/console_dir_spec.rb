require "spec_helper"
require "rack/test"
require "tmpdir"

# `--console-dir PATH` makes the daemon serve the SPA static
# directory at /console/* in the same process. Same-origin with
# /v1, so the cookie session set by POST /v1/login rides every
# subsequent request — no CORS plumbing needed.
RSpec.describe "console-dir static serving" do
  include Rack::Test::Methods

  let(:db)        { Prouterd::Storage::DB.open(":memory:") }
  let(:store)     { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner)    { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics)   { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:jobs)      { Prouterd::Storage::Repositories::Jobs.new(db) }

  let(:console_dir) do
    dir = Dir.mktmpdir("console-")
    File.write(File.join(dir, "index.html"), "<html><body>console</body></html>")
    File.write(File.join(dir, "login.html"), "<html><body>login</body></html>")
    Dir.mkdir(File.join(dir, "assets"))
    File.write(File.join(dir, "assets", "app.css"), "body { color: red; }")
    dir
  end

  let(:app) do
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics, admin_token: nil,
      console_dir: console_dir
    )
  end

  after do
    db.close
    FileUtils.remove_entry(console_dir)
  end

  it "serves index.html at /console" do
    get "/console"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to include("text/html")
    expect(last_response.body).to include("console")
  end

  it "serves index.html at /console/" do
    get "/console/"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("console")
  end

  it "serves named files with content-type from extension" do
    get "/console/login.html"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to include("text/html")

    get "/console/assets/app.css"
    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to include("text/css")
    expect(last_response.body).to include("color: red")
  end

  it "404s on missing files" do
    get "/console/no-such-file.js"
    expect(last_response.status).to eq(404)
  end

  it "rejects directory-traversal segments" do
    get "/console/../etc/passwd"
    expect([400, 404]).to include(last_response.status)

    # Even URL-encoded `..` shouldn't escape (Rack normalises the path
    # already; we double-check the segment-level guard.)
    get "/console/%2e%2e/etc/passwd"
    expect([400, 404]).to include(last_response.status)
  end

  it "405s on POST" do
    post "/console/index.html"
    expect(last_response.status).to eq(405)
  end

  it "/v1 still works alongside /console" do
    get "/v1/status"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["accepting"]).to be(true)
  end

  it "skips static serving when console_dir is unset" do
    plain_app = Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics, admin_token: nil
    )
    env = Rack::MockRequest.env_for("/console", method: "GET")
    status, _, _ = plain_app.call(env)
    expect(status).to eq(404)
  end
end
