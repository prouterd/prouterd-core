require "spec_helper"
require "rack/test"
require "faye/websocket"

# Cover the parts of App that the main spec doesn't:
# accepting toggles, storage probe lifecycle, WS dispatch, every /v1
# route branch (including the dynamic ones), serve_console bad-path
# branches, parse_json_body rescue, and request_is_https?
RSpec.describe Prouterd::API::App do
  include Rack::Test::Methods

  let(:db)        { Prouterd::Storage::DB.open(":memory:") }
  let(:store)     { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner)    { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics)   { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:jobs)      { Prouterd::Storage::Repositories::Jobs.new(db) }

  let(:app) do
    described_class.new(
      store: store, runner: runner, jobs: jobs,
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
      interface manual cli
       no shutdown
      exit
      interface docker img1
       image alpine:1
      exit
      process pipeline
       block extract
        interface docker img1
       exit
      exit
      route interface cli process pipeline
      exit
    PRC
  end

  before { store.commit(document) }

  describe "#accepting? + #resume_accepting" do
    it "starts true, stop_accepting flips false, resume_accepting flips back true" do
      expect(app.accepting?).to be(true)
      app.stop_accepting
      expect(app.accepting?).to be(false)
      app.resume_accepting
      expect(app.accepting?).to be(true)
    end
  end

  describe "storage probe" do
    it "is a no-op when called twice (idempotent thread creation)" do
      ENV["PROUTERD_STORAGE_PROBE_SECONDS"] = "999"  # long enough that we control loop
      app.start_storage_probe
      first_thread = app.instance_variable_get(:@storage_probe_thread)
      app.start_storage_probe
      second_thread = app.instance_variable_get(:@storage_probe_thread)
      expect(second_thread).to equal(first_thread)
    ensure
      app.stop_storage_probe
      ENV.delete("PROUTERD_STORAGE_PROBE_SECONDS")
    end

    it "stop_storage_probe is safe when nothing was started" do
      expect { app.stop_storage_probe }.not_to raise_error
    end

    it "flips accepting back to true when probe sees healthy after a failure" do
      app.stop_accepting  # simulate prior failure
      expect(app.accepting?).to be(false)

      logger = double("logger")
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      app.instance_variable_set(:@logger, logger)
      allow(store.db).to receive(:healthy?).and_return(true)
      allow(app).to receive(:sleep)         # short-circuit the loop's wait
      expect(logger).to receive(:info).with(
        "writes recovered, accepting requests",
        hash_including(facility: "STORE", mnemonic: "RECOVERED")
      )

      # Run one iteration of the loop body inline by extracting it.
      ENV["PROUTERD_STORAGE_PROBE_SECONDS"] = "0"
      app.start_storage_probe
      # Give the probe thread a couple of ticks to run.
      sleep 0.05
      app.stop_storage_probe
      expect(app.accepting?).to be(true)
    ensure
      ENV.delete("PROUTERD_STORAGE_PROBE_SECONDS")
    end

    it "flips accepting off when probe sees unhealthy while accepting" do
      expect(app.accepting?).to be(true)
      logger = double("logger")
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      app.instance_variable_set(:@logger, logger)
      allow(store.db).to receive(:healthy?).and_return(false)
      expect(logger).to receive(:warn).with(
        "writes failing, rejecting state-changing requests",
        hash_including(facility: "STORE", mnemonic: "FAILING")
      )
      ENV["PROUTERD_STORAGE_PROBE_SECONDS"] = "0"
      app.start_storage_probe
      sleep 0.05
      app.stop_storage_probe
      expect(app.accepting?).to be(false)
    ensure
      ENV.delete("PROUTERD_STORAGE_PROBE_SECONDS")
    end

    it "rescues StandardError raised by the healthy? check" do
      logger = double("logger")
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      app.instance_variable_set(:@logger, logger)
      allow(store.db).to receive(:healthy?).and_raise(StandardError, "probe boom")
      expect(logger).to receive(:error).with(
        "storage probe error",
        hash_including(facility: "STORE", mnemonic: "PROBE_ERR",
                       error: "StandardError", message: "probe boom")
      ).at_least(:once)
      ENV["PROUTERD_STORAGE_PROBE_SECONDS"] = "0"
      app.start_storage_probe
      sleep 0.05
      app.stop_storage_probe
    ensure
      ENV.delete("PROUTERD_STORAGE_PROBE_SECONDS")
    end
  end

  describe "App#call top-level dispatch" do
    it "dispatches /v1/config/startup → V1#get_config_startup (404 when unset)" do
      get "/v1/config/startup"
      expect(last_response.status).to eq(404)
    end

    it "dispatches /v1/tools" do
      get "/v1/tools"
      expect(last_response.status).to eq(200)
    end

    it "dispatches /v1/mcp" do
      get "/v1/mcp"
      expect(last_response.status).to eq(200)
    end

    it "dispatches GET /v1/local-repo/status" do
      get "/v1/local-repo/status"
      expect(last_response.status).to eq(200)
    end

    it "dispatches GET /v1/config/commits/:id" do
      commit_id = store.running_commit.id
      get "/v1/config/commits/#{commit_id}"
      expect(last_response.status).to eq(200)
    end

    it "dispatches POST /v1/runs/:uid/resume" do
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs_repo.create_run(process_name: "pipeline", input_event: {})
      runs_repo.update_run(r.id, status: "running")
      post "/v1/runs/#{r.uid}/resume"
      # Not paused → 409
      expect(last_response.status).to eq(409)
    end

    it "404 on an unknown /v1 path (catch-all in dispatch_v1_dynamic)" do
      get "/v1/something/that/does/not/exist"
      expect(last_response.status).to eq(404)
    end

    it "returns 503 with storage_unavailable when the store raises DiskUnavailableError" do
      allow(store).to receive(:load_running)
        .and_raise(Prouterd::Storage::DiskUnavailableError, "disk full")
      get "/v1/processes"
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("storage_unavailable")
      # @accepting flipped to false
      expect(app.accepting?).to be(false)
    end

    it "returns 500 internal_error on any other StandardError, with a backtrace logged" do
      logger = double("logger")
      allow(logger).to receive(:error)
      app.instance_variable_set(:@logger, logger)
      allow(store).to receive(:load_running).and_raise(StandardError, "oops")
      expect(logger).to receive(:error).with(
        "internal API error",
        hash_including(facility: "API", mnemonic: "INTERNAL", error: "StandardError", message: "oops")
      )
      get "/v1/processes"
      expect(last_response.status).to eq(500)
    end

    it "404 on a request that matches no route at all (not /v1/*, not /i/*, not /console)" do
      get "/totally-not-a-route"
      expect(last_response.status).to eq(404)
    end
  end

  describe "WS dispatch" do
    it "404 on a WS upgrade to an unknown ws path" do
      env = Rack::MockRequest.env_for("/v1/notawsroute",
        "HTTP_UPGRADE"    => "websocket",
        "HTTP_CONNECTION" => "Upgrade",
        "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
        "HTTP_SEC_WEBSOCKET_VERSION" => "13")
      status, _, _ = app.call(env)
      expect(status).to eq(404)
    end

    it "routes /v1/events upgrade through EventsWebSocket.handle" do
      env = Rack::MockRequest.env_for("/v1/events",
        "HTTP_UPGRADE"    => "websocket",
        "HTTP_CONNECTION" => "Upgrade",
        "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
        "HTTP_SEC_WEBSOCKET_VERSION" => "13")
      expect(Prouterd::API::EventsWebSocket).to receive(:handle).and_return([101, {}, []])
      status, _, _ = app.call(env)
      expect(status).to eq(101)
    end

    it "routes /v1/cli/:sid upgrade through CliWebSocket.handle" do
      env = Rack::MockRequest.env_for("/v1/cli/abc-123",
        "HTTP_UPGRADE"    => "websocket",
        "HTTP_CONNECTION" => "Upgrade",
        "HTTP_SEC_WEBSOCKET_KEY" => "dGhlIHNhbXBsZSBub25jZQ==",
        "HTTP_SEC_WEBSOCKET_VERSION" => "13")
      expect(Prouterd::API::CliWebSocket).to receive(:handle)
        .with(anything, hash_including(session_id: "abc-123")).and_return([101, {}, []])
      status, _, _ = app.call(env)
      expect(status).to eq(101)
    end
  end

  describe "/console bad-path branches" do
    let(:console_dir) do
      dir = Dir.mktmpdir("console-bad-")
      File.write(File.join(dir, "index.html"), "<html>x</html>")
      dir
    end

    let(:app) do
      described_class.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: in_flight, metrics: metrics, admin_token: nil,
        console_dir: console_dir
      )
    end

    after { FileUtils.remove_entry(console_dir) }

    it "rejects paths that start with /" do
      env = Rack::MockRequest.env_for("/console//etc/passwd", method: "GET")
      status, _, _ = app.call(env)
      # Rack normalises double-slash; tail starts with `/` if any segment was empty
      # We at least want a 400 OR 404 (no traversal escape).
      expect([400, 404]).to include(status)
    end

    it "rejects an embedded NUL byte" do
      # Build the env manually so we can leave the NUL untouched.
      env = Rack::MockRequest.env_for("/console/foo", method: "GET")
      env["PATH_INFO"] = "/console/foo\0bar"
      status, _, _ = app.call(env)
      expect(status).to eq(400)
    end
  end

  describe "parse_json_body rescue" do
    it "returns 401 (treating empty/garbage body as nil) on /v1/login with bad JSON" do
      # admin_token mode required to even reach parse_json_body inside login_response.
      a = described_class.new(store: store, runner: runner, jobs: jobs,
                              in_flight: in_flight, metrics: metrics,
                              admin_token: "topsecret")
      env = Rack::MockRequest.env_for("/v1/login", method: "POST",
                                       input: "{not valid json")
      env["CONTENT_TYPE"] = "application/json"
      status, _, body = a.call(env)
      body_str = body.is_a?(Array) ? body.join : body.to_s
      expect(status).to eq(401)
      expect(JSON.parse(body_str).dig("error", "code")).to eq("unauthorized")
    end
  end

  describe "request_is_https? coverage" do
    let(:a) do
      described_class.new(store: store, runner: runner, jobs: jobs,
                          in_flight: in_flight, metrics: metrics,
                          admin_token: "topsecret")
    end

    it "treats env['HTTPS'] == 'on' as https" do
      env = Rack::MockRequest.env_for("/v1/login", method: "POST",
                                       input: JSON.dump(token: "topsecret"))
      env["CONTENT_TYPE"] = "application/json"
      env["HTTPS"] = "on"
      _, headers, _ = a.call(env)
      expect(headers["set-cookie"].to_s).to include("Secure")
    end

    it "treats env['rack.url_scheme'] == 'https' as https" do
      env = Rack::MockRequest.env_for("/v1/login", method: "POST",
                                       input: JSON.dump(token: "topsecret"))
      env["CONTENT_TYPE"] = "application/json"
      env["rack.url_scheme"] = "https"
      _, headers, _ = a.call(env)
      expect(headers["set-cookie"].to_s).to include("Secure")
    end
  end

  describe "graceful-shutdown rejection envelopes" do
    it "returns 503 with code:'unavailable' on a state-changing POST after stop_accepting" do
      app.stop_accepting
      header "content-type", "application/json"
      post "/v1/config/apply", "router demo\nexit\n"
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unavailable")
    end
  end

  describe "status_payload nil branches" do
    it "in_flight nil → status reports in_flight: nil" do
      a = described_class.new(store: store, runner: runner, jobs: jobs,
                              in_flight: nil, metrics: metrics, admin_token: nil)
      env = Rack::MockRequest.env_for("/v1/status", method: "GET")
      status, _, body = a.call(env)
      body_str = body.is_a?(Array) ? body.join : body.to_s
      expect(status).to eq(200)
      expect(JSON.parse(body_str)["in_flight"]).to be_nil
    end
  end

  describe "metrics_response with no metrics configured" do
    it "returns 200 + JSON error stub when @metrics is nil" do
      a = described_class.new(store: store, runner: runner, jobs: jobs,
                              in_flight: in_flight, metrics: nil, admin_token: nil)
      env = Rack::MockRequest.env_for("/metrics", method: "GET")
      status, headers, body = a.call(env)
      body_str = body.is_a?(Array) ? body.join : body.to_s
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("application/json")
      expect(JSON.parse(body_str)["error"]).to eq("metrics not configured")
    end
  end
end
