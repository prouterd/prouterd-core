require "spec_helper"
require "rack/test"

# Cookie-session auth: POST /v1/login mints an HttpOnly cookie that
# subsequent requests can present in lieu of the bearer. Bearer auth
# stays alive for curl / k8s / automation.
RSpec.describe "Cookie-session auth" do
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
      in_flight: in_flight, metrics: metrics, admin_token: "topsecret"
    )
  end

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      process pipeline
       block extract
        interface docker img1
       exit
      exit
      interface docker img1
       image alpine:1
      exit
      route interface cli process pipeline
      exit
    PRC
  end
  before { store.commit(document) }
  after  { db.close }

  describe "POST /v1/login" do
    it "rejects an empty body" do
      post "/v1/login", "", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(401)
    end

    it "rejects the wrong token" do
      post "/v1/login", JSON.dump(token: "nope"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(401)
    end

    it "accepts the right token and sets an HttpOnly Set-Cookie" do
      post "/v1/login", JSON.dump(token: "topsecret"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      cookie = last_response.headers["set-cookie"].to_s
      expect(cookie).to match(/\Aprouterd_session=[0-9a-f]{64}/)
      expect(cookie).to include("HttpOnly")
      expect(cookie).to include("SameSite=Lax")
      expect(cookie).to include("Path=/")
    end

    it "open-mode (no admin_token) returns 204 no-op" do
      open_app = Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics, admin_token: nil
      )
      env = Rack::MockRequest.env_for("/v1/login", method: "POST", input: "{}")
      env["CONTENT_TYPE"] = "application/json"
      status, _, _ = open_app.call(env)
      expect(status).to eq(204)
    end

    it "marks the cookie Secure on HTTPS-forwarded requests" do
      header "X-Forwarded-Proto", "https"
      post "/v1/login", JSON.dump(token: "topsecret"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.headers["set-cookie"].to_s).to include("Secure")
    end
  end

  describe "cookie session unlocks /v1/* without bearer" do
    def login_and_get_cookie
      post "/v1/login", JSON.dump(token: "topsecret"),
           { "CONTENT_TYPE" => "application/json" }
      cookie = last_response.headers["set-cookie"].to_s
      cookie[/\Aprouterd_session=[^;]+/]
    end

    it "/v1/processes accepts a valid session cookie alone" do
      cookie = login_and_get_cookie
      header "Cookie", cookie
      get "/v1/processes"
      expect(last_response.status).to eq(200)
    end

    it "rejects a forged session id" do
      header "Cookie", "prouterd_session=deadbeef"
      get "/v1/processes"
      expect(last_response.status).to eq(401)
    end

    it "still accepts the bearer header path (curl / k8s)" do
      header "Authorization", "Bearer topsecret"
      get "/v1/processes"
      expect(last_response.status).to eq(200)
    end
  end

  describe "POST /v1/logout" do
    it "revokes the session and clears the cookie" do
      post "/v1/login", JSON.dump(token: "topsecret"),
           { "CONTENT_TYPE" => "application/json" }
      cookie = last_response.headers["set-cookie"].to_s[/\Aprouterd_session=[^;]+/]

      header "Cookie", cookie
      post "/v1/logout"
      expect(last_response.status).to eq(204)
      expect(last_response.headers["set-cookie"].to_s).to include("Max-Age=0")

      # Same cookie value no longer authorises.
      header "Cookie", cookie
      get "/v1/processes"
      expect(last_response.status).to eq(401)
    end

    it "logout without a session is idempotent (still 204)" do
      post "/v1/logout"
      expect(last_response.status).to eq(204)
    end
  end
end
