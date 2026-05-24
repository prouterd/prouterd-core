require "spec_helper"
require "rack"
require "ostruct"

RSpec.describe Prouterd::API::WebhookHandler do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def post_request(body: "{}", method: "POST", headers: {})
    env = Rack::MockRequest.env_for(
      "/i/wh", method: method, input: body
    ).merge(headers)
    Rack::Request.new(env)
  end

  let(:handler) do
    described_class.new(
      store: store, runner: runner, jobs: jobs,
      logger: Prouterd::NullLogger.new
    )
  end

  describe "rate-limited path without metrics" do
    it "returns 429 even when metrics is nil (no NoMethodError on the &. branch)" do
      store.commit(parse(<<~PRC))
        router demo
        exit
        interface webhook wh
         path /wh
         method POST
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
        exit
        route interface wh process p
        exit
      PRC

      # Real RateLimiter that's pre-exhausted: cap=1 / window=1s, then
      # we call it once below to use up the budget, then the actual
      # webhook hits the deny path. Constructed without metrics (nil).
      rl = Prouterd::API::RateLimiter.new(max_requests: 1, window_seconds: 60)
      rl.allow?("wh") # consume the single slot

      h = described_class.new(store: store, runner: runner, jobs: jobs,
                              logger: Prouterd::NullLogger.new,
                              rate_limiter: rl) # NO metrics:
      status, _h, body = h.handle("wh", post_request)
      expect(status).to eq(429)
      expect(body.first).to include("rate_limited")
    end
  end

  describe "global route targeting an unknown process" do
    it "returns 500 internal_error when the route references a missing process" do
      # Build a document where `route interface wh process pX` exists,
      # then delete the process row in-place so the route is dangling.
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook wh
         path /wh
         method POST
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
        exit
        route interface wh process p
        exit
      PRC
      doc.processes.clear # strip processes after the route was bound
      allow(store).to receive(:load_running).and_return(doc)
      status, _h, body = handler.handle("wh", post_request)
      expect(status).to eq(500)
      expect(body.first).to include("unknown process 'p'")
    end
  end

  describe "global route targeting a shutdown process" do
    it "returns 503 unavailable" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface webhook wh
         path /wh
         method POST
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         shutdown
         block a
          interface docker img
         exit
        exit
        route interface wh process p
        exit
      PRC
      allow(store).to receive(:load_running).and_return(doc)
      status, _h, body = handler.handle("wh", post_request)
      expect(status).to eq(503)
      expect(body.first).to include("is shutdown")
    end
  end

  describe "resolve_secret with a missing secret declaration" do
    it "returns nil from the resolver and surfaces a 500 from the HMAC path" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret HMAC_KEY
         source env HMAC_KEY
        exit
        interface webhook wh
         path /wh
         method POST
         hmac-sha256 secret HMAC_KEY header X-Sig
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
        exit
        route interface wh process p
        exit
      PRC
      doc.secrets.clear # drop the declared secret while the iface still references it
      allow(store).to receive(:load_running).and_return(doc)
      status, _h, body = handler.handle(
        "wh",
        post_request(body: "{}", headers: { "HTTP_X_SIG" => "deadbeef" })
      )
      expect(status).to eq(500)
      expect(body.first).to include("secret_unresolved")
    end
  end

  describe "running commit pinning when there is no running pointer" do
    it "passes commit_id: nil to enqueue when @store.running_commit is nil" do
      store.commit(parse(<<~PRC))
        router demo
        exit
        interface webhook wh
         path /wh
         method POST
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
        exit
        route interface wh process p
        exit
      PRC
      # Commit landed → load_running returns the doc. Now nil-out the
      # running-pointer accessor only, so the webhook still finds the
      # iface/process but `running_commit&.id` short-circuits to nil.
      allow(store).to receive(:running_commit).and_return(nil)

      status, _h, _body = handler.handle("wh", post_request)
      expect(status).to eq(202)
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      latest = runs_repo.list_runs(limit: 1).first
      expect(latest.process_config_commit_id).to be_nil
    end
  end

  describe "json_error with details (private helper)" do
    it "merges details into the body when present" do
      status, _h, body = handler.send(:json_error, 400, "bad", "msg", details: { hint: "x" })
      expect(status).to eq(400)
      payload = JSON.parse(body.first)
      expect(payload["error"]).to include("code" => "bad", "message" => "msg", "details" => { "hint" => "x" })
    end
  end
end
