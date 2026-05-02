require "spec_helper"
require "rack/test"
require "timeout"

RSpec.describe Prouterd::API::App do
  include Rack::Test::Methods

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:app) { described_class.new(store: store, runner: runner) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:config_with_webhook) do
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
       no shutdown
      exit
      process pipeline
       block extract
        image x
        input event.body
        output result
       exit
      exit
      route interface leads_in process pipeline
       match event.type eq "lead.created"
      exit
    PRC
  end

  def commit(doc)
    store.commit(doc)
  end

  describe "GET /v1/status" do
    it "returns hostname, version, and counts" do
      commit(config_with_webhook)
      get "/v1/status"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["version"]).to eq(Prouterd::VERSION)
      expect(body["interfaces"]).to eq(1)
      expect(body["processes"]).to eq(1)
      expect(body["running_commit"]).to be_a(Integer)
    end
  end

  describe "POST /i/<unknown>" do
    it "returns 404" do
      commit(config_with_webhook)
      post "/i/ghost"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body)["error"]).to include("ghost")
    end
  end

  describe "POST /i/<webhook>" do
    before do
      commit(config_with_webhook)
      ENV["WEBHOOK_TOKEN"] = "supersecret"
      runner.default(&Prouterd::Runner::StubRunner.success)
    end
    after { ENV.delete("WEBHOOK_TOKEN") }

    it "rejects requests without a bearer token" do
      header "content-type", "application/json"
      post "/i/leads_in", JSON.dump(type: "lead.created", body: {})
      expect(last_response.status).to eq(401)
    end

    it "rejects requests with the wrong token" do
      header "authorization", "Bearer wrong"
      header "content-type", "application/json"
      post "/i/leads_in", JSON.dump(type: "lead.created", body: {})
      expect(last_response.status).to eq(403)
    end

    it "accepts and enqueues a run with the right token" do
      header "authorization", "Bearer supersecret"
      header "content-type", "application/json"
      post "/i/leads_in", JSON.dump(type: "lead.created", body: { name: "Acme" })
      expect(last_response.status).to eq(202)
      body = JSON.parse(last_response.body)
      expect(body["run_id"]).to match(/\Arun_[0-9a-f]+\z/)
      expect(body["status"]).to eq("queued")

      # The run row exists right away (worker thread hasn't necessarily
      # finished, but creation is synchronous).
      repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = repo.get_run_by_uid(body["run_id"])
      expect(run).not_to be_nil
      expect(run.process_name).to eq("pipeline")
      expect(run.interface_name).to eq("leads_in")
      expect(JSON.parse(run.input_event_json)).to eq("type" => "lead.created", "body" => { "name" => "Acme" })
    end

    it "rejects events that do not match the global route condition" do
      header "authorization", "Bearer supersecret"
      header "content-type", "application/json"
      post "/i/leads_in", JSON.dump(type: "lead.archived", body: {})
      expect(last_response.status).to eq(422)
    end

    it "rejects requests when the interface is shutdown" do
      doc = parse(<<~PRC)
        router x
        exit
        secret T
         source env T
        exit
        interface webhook iface
         path /x
         method POST
         shutdown
        exit
        process p
         block a
          image x
          output r
         exit
        exit
        route interface iface process p
        exit
      PRC
      commit(doc)
      header "content-type", "application/json"
      post "/i/iface", "{}"
      expect(last_response.status).to eq(503)
    end

    it "returns 400 on malformed JSON" do
      header "authorization", "Bearer supersecret"
      header "content-type", "application/json"
      post "/i/leads_in", "{not valid"
      expect(last_response.status).to eq(400)
    end
  end

  describe "Phase 7 async dispatch" do
    it "executes the run in the background and the run completes asynchronously" do
      commit(config_with_webhook)
      ENV["WEBHOOK_TOKEN"] = "tok"

      # Use a synchronization barrier so we can confirm the request returns
      # BEFORE the run finishes — proving the dispatch is truly async.
      release_runner = Queue.new
      runner.default do |req|
        release_runner.pop  # block until the test releases us
        Prouterd::Runner::StubRunner.success.call(req)
      end

      header "authorization", "Bearer tok"
      header "content-type", "application/json"
      post "/i/leads_in", JSON.dump(type: "lead.created", body: { name: "x" })
      expect(last_response.status).to eq(202)
      body = JSON.parse(last_response.body)

      repo = Prouterd::Storage::Repositories::Runs.new(db)
      # At this moment the runner is still blocked inside the worker thread,
      # so the run is `running` (not yet success).
      Timeout.timeout(2) do
        loop do
          status = repo.get_run_by_uid(body["run_id"])&.status
          break if %w[running queued].include?(status)
          sleep 0.01
        end
      end

      release_runner << :go
      Timeout.timeout(2) do
        loop do
          break if repo.get_run_by_uid(body["run_id"])&.status == "success"
          sleep 0.01
        end
      end

      ENV.delete("WEBHOOK_TOKEN")
    end
  end
end
