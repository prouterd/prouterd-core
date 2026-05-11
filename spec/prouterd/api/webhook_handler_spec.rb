require "spec_helper"
require "rack"
require "json"
require "openssl"

RSpec.describe Prouterd::API::WebhookHandler do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics) { Prouterd::API::Metrics.new }
  let(:handler) do
    described_class.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics
    )
  end

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def request(method: "POST", body: "{}", headers: {}, path: "/i/leads_in")
    env = Rack::MockRequest.env_for(path, method: method, input: body)
    headers.each { |k, v| env[k] = v }
    Rack::Request.new(env)
  end

  def parse_body(body)
    JSON.parse(Array(body).join)
  end

  let(:basic_config) do
    parse(<<~PRC)
      router demo
      exit
      interface webhook leads_in
       path /leads
       method POST
       no shutdown
      exit
      interface shell host
      exit
      process pipeline
       block work
        interface shell host
        exec `echo '{"ok":true}'`
       exit
      exit
      route interface leads_in process pipeline
      exit
    PRC
  end

  describe "interface lookup" do
    it "404s on unknown interface" do
      store.commit(basic_config)
      status, _, body = handler.handle("nonexistent", request)
      expect(status).to eq(404)
      expect(parse_body(body).dig("error", "code")).to eq("not_found")
      expect(parse_body(body).dig("error", "message")).to include("unknown interface")
    end

    it "404s when the interface exists but is not a webhook" do
      store.commit(basic_config)
      status, _, body = handler.handle("host", request)
      expect(status).to eq(404)
      expect(parse_body(body).dig("error", "message")).to include("is not a webhook")
    end

    it "503s when the interface is shutdown" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook leads_in
         path /leads
         method POST
         shutdown
        exit
        interface shell host
        exit
        process pipeline
         block w
          interface shell host
          exec `echo '{}'`
         exit
        exit
        route interface leads_in process pipeline
        exit
      PRC
      store.commit(doc)
      status, _, body = handler.handle("leads_in", request)
      expect(status).to eq(503)
      expect(parse_body(body).dig("error", "code")).to eq("unavailable")
    end
  end

  describe "method enforcement" do
    it "405s with Allow header on a method mismatch" do
      store.commit(basic_config)
      status, headers, body = handler.handle("leads_in", request(method: "GET", body: ""))
      expect(status).to eq(405)
      expect(headers["allow"]).to eq("POST")
      expect(parse_body(body).dig("error", "code")).to eq("method_not_allowed")
    end
  end

  describe "rate limiting" do
    it "429s when the rate limiter refuses and increments the metric" do
      store.commit(basic_config)
      rate_limiter = instance_double("RateLimiter", allow?: false)
      h = described_class.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics, rate_limiter: rate_limiter
      )
      status, _, body = h.handle("leads_in", request)
      expect(status).to eq(429)
      expect(parse_body(body).dig("error", "code")).to eq("rate_limited")
      expect(metrics.counters[[:webhooks_received_total,
                               { interface: "leads_in", code: 429 }]]).to eq(1)
    end
  end

  describe "bearer auth" do
    let(:auth_config) do
      ENV["WEBHOOK_TOKEN"] = "the-token"
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
        exit
        interface shell host
        exit
        process pipeline
         block w
          interface shell host
          exec `echo '{}'`
         exit
        exit
        route interface leads_in process pipeline
        exit
      PRC
    end

    after { ENV.delete("WEBHOOK_TOKEN") }

    it "401s on a missing bearer" do
      store.commit(auth_config)
      status, _, body = handler.handle("leads_in", request)
      expect(status).to eq(401)
      expect(parse_body(body).dig("error", "code")).to eq("unauthorized")
    end

    it "403s on a wrong bearer" do
      store.commit(auth_config)
      req = request(headers: { "HTTP_AUTHORIZATION" => "Bearer wrong" })
      status, _, body = handler.handle("leads_in", req)
      expect(status).to eq(403)
      expect(parse_body(body).dig("error", "code")).to eq("forbidden")
    end

    it "lets through the right bearer (returns 202 queued)" do
      store.commit(auth_config)
      req = request(headers: { "HTTP_AUTHORIZATION" => "Bearer the-token" })
      status, _, body = handler.handle("leads_in", req)
      expect(status).to eq(202)
      expect(parse_body(body)["status"]).to eq("queued")
    end
  end

  describe "HMAC-SHA256 verification" do
    let(:hmac_secret) { "shared-secret" }
    let(:body) { JSON.dump(name: "Acme", type: "lead.created") }
    let(:hmac_config) do
      ENV["HMAC_KEY"] = hmac_secret
      parse(<<~PRC)
        router demo
        exit
        secret HMAC_KEY
         source env HMAC_KEY
        exit
        interface webhook leads_in
         path /leads
         method POST
         hmac-sha256 secret HMAC_KEY header X-Hub-Signature-256
        exit
        interface shell host
        exit
        process pipeline
         block w
          interface shell host
          exec `echo '{}'`
         exit
        exit
        route interface leads_in process pipeline
        exit
      PRC
    end

    after { ENV.delete("HMAC_KEY") }

    def sign(body, prefix: "sha256=")
      digest = OpenSSL::HMAC.hexdigest("sha256", hmac_secret, body)
      "#{prefix}#{digest}"
    end

    it "401s on mismatched signature" do
      store.commit(hmac_config)
      req = request(body: body,
                    headers: { "HTTP_X_HUB_SIGNATURE_256" => "sha256=deadbeef" })
      status, _, response_body = handler.handle("leads_in", req)
      expect(status).to eq(401)
      expect(parse_body(response_body).dig("error", "message")).to include("hmac")
      expect(metrics.counters[[:webhooks_received_total,
                               { interface: "leads_in", code: 401 }]]).to eq(1)
    end

    it "accepts a valid sha256=<hex> signature (GitHub-style prefix)" do
      store.commit(hmac_config)
      req = request(body: body,
                    headers: { "HTTP_X_HUB_SIGNATURE_256" => sign(body, prefix: "sha256=") })
      status, _, response_body = handler.handle("leads_in", req)
      expect(status).to eq(202)
      expect(parse_body(response_body)["status"]).to eq("queued")
    end

    it "accepts a valid v0=<hex> signature (Slack-style prefix)" do
      store.commit(hmac_config)
      req = request(body: body,
                    headers: { "HTTP_X_HUB_SIGNATURE_256" => sign(body, prefix: "v0=") })
      status, _, _ = handler.handle("leads_in", req)
      expect(status).to eq(202)
    end

    it "500s with secret_unresolved when the HMAC secret can't be resolved" do
      # Commit FIRST so the let block lands the config; then drop the
      # env var so secret resolution at request-time fails.
      store.commit(hmac_config)
      ENV.delete("HMAC_KEY")
      req = request(body: body,
                    headers: { "HTTP_X_HUB_SIGNATURE_256" => "sha256=anything" })
      status, _, response_body = handler.handle("leads_in", req)
      expect(status).to eq(500)
      expect(parse_body(response_body).dig("error", "code")).to eq("secret_unresolved")
    end
  end

  describe "body parsing" do
    it "400s on malformed JSON" do
      store.commit(basic_config)
      status, _, body = handler.handle("leads_in", request(body: "not-json{"))
      expect(status).to eq(400)
      expect(parse_body(body).dig("error", "code")).to eq("bad_json")
    end

    it "accepts an empty body and treats it as {}" do
      store.commit(basic_config)
      status, _, body = handler.handle("leads_in", request(body: ""))
      expect(status).to eq(202)
      expect(parse_body(body)["status"]).to eq("queued")
    end
  end

  describe "routing and matching" do
    it "422s when no match clause passes" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook leads_in
         path /leads
         method POST
        exit
        interface shell host
        exit
        process pipeline
         block w
          interface shell host
          exec `echo '{}'`
         exit
        exit
        route interface leads_in process pipeline
         match event.type eq "needed"
        exit
      PRC
      store.commit(doc)
      status, _, body = handler.handle("leads_in", request(body: '{"type":"other"}'))
      expect(status).to eq(422)
      expect(parse_body(body).dig("error", "code")).to eq("unprocessable")
    end

    it "404s when the interface has no matching global route" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook orphan_in
         path /orphan
         method POST
        exit
        interface shell host
        exit
        process p
         block w
          interface shell host
          exec `echo '{}'`
         exit
        exit
      PRC
      store.commit(doc)
      status, _, body = handler.handle("orphan_in", request)
      expect(status).to eq(404)
      expect(parse_body(body).dig("error", "message")).to include("no global route")
    end
  end

  describe "happy path" do
    it "returns 202 with run_id, enqueues a run + a job atomically, increments metric" do
      store.commit(basic_config)
      status, headers, body = handler.handle("leads_in", request(body: '{"name":"Acme"}'))

      expect(status).to eq(202)
      expect(headers["content-type"]).to eq("application/json")
      payload = parse_body(body)
      expect(payload["status"]).to eq("queued")
      expect(payload["run_id"]).to match(/\Arun_[0-9a-f]+\z/)

      expect(metrics.counters[[:webhooks_received_total,
                               { interface: "leads_in", code: 202 }]]).to eq(1)

      # Job actually landed on the queue (durable, recoverable).
      job = jobs.claim("test-worker")
      expect(job).not_to be_nil
      expect(job.kind).to eq("execute")
    end
  end
end
