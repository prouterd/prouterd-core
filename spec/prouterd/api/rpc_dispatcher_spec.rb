require "spec_helper"

RSpec.describe Prouterd::API::RpcDispatcher do
  let(:db)        { Prouterd::Storage::DB.open(":memory:") }
  let(:store)     { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner)    { Prouterd::Runner::StubRunner.new }
  let(:in_flight) { Prouterd::Runtime::InFlightRegistry.new }
  let(:metrics)   { Prouterd::API::Metrics.new(in_flight: in_flight) }
  let(:jobs)      { Prouterd::Storage::Repositories::Jobs.new(db) }

  let(:app) do
    Prouterd::API::App.new(
      store: store, runner: runner, jobs: jobs,
      in_flight: in_flight, metrics: metrics, admin_token: nil
    )
  end
  let(:v1) { app.instance_variable_get(:@v1) }

  subject(:dispatcher) { described_class.new(v1: v1, app: app, store: store) }

  let(:document) do
    parser = Prouterd::Config::Parser
    lexer  = Prouterd::Config::Lexer
    parser.parse(lexer.tokenize(<<~PRC))
      router demo
      exit
      queue default
       concurrency 2
       timeout 30s
      exit
      interface docker img1
       image alpine:1
      exit
      process pipeline
       queue default
       block extract
        interface docker img1
       exit
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end
  after { db.close }

  describe "method dispatch" do
    it "status returns the same payload as App#status_payload" do
      result = dispatcher.call("status", {})
      expect(result[:type]).to eq("reply")
      expect(result[:payload][:router]).to eq("demo")
      expect(result[:payload][:processes]).to eq(1)
    end

    it "processes.list returns the V1 processes list" do
      result = dispatcher.call("processes.list", {})
      expect(result[:type]).to eq("reply")
      processes = result[:payload]["data"]
      expect(processes.first["name"]).to eq("pipeline")
    end

    it "processes.get returns one process by name" do
      result = dispatcher.call("processes.get", { "name" => "pipeline" })
      expect(result[:type]).to eq("reply")
      expect(result[:payload]["data"]["name"]).to eq("pipeline")
    end

    it "processes.get → not_found error for unknown name" do
      result = dispatcher.call("processes.get", { "name" => "nope" })
      expect(result[:type]).to eq("error")
      expect(result[:payload][:code]).to eq("not_found")
    end

    it "interfaces.list / queues.list / policies.list / secrets.list all reply" do
      %w[interfaces.list queues.list policies.list secrets.list].each do |m|
        r = dispatcher.call(m, {})
        expect(r[:type]).to eq("reply"), "expected reply for #{m}, got #{r.inspect}"
        expect(r[:payload]).to have_key("data")
      end
    end

    it "config.commits exposes meta.running" do
      r = dispatcher.call("config.commits", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["meta"]["running"]).to be_a(Integer)
    end

    it "config.running returns the rendered DSL as a bare string" do
      r = dispatcher.call("config.running", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]).to be_a(String)
      expect(r[:payload]).to include("router demo")
    end

    it "runs.list with no runs yet returns an empty data array" do
      r = dispatcher.call("runs.list", {})
      expect(r[:type]).to eq("reply")
      expect(r[:payload]["data"]).to eq([])
    end

    it "trace dispatches into V1 with body={event, interface}" do
      r = dispatcher.call("trace", { "event" => { "type" => "x" } })
      expect(r[:type]).to eq("reply")
      expect(r[:payload]).to have_key("data")
    end

    it "runs.resume_by_thread → not_found when thread has no paused run" do
      r = dispatcher.call("runs.resume_by_thread", { "thread_id" => "nope", "value" => {} })
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("not_found")
      expect(r[:payload][:message]).to include("no paused run")
    end

    it "unknown method returns code:'unknown_method'" do
      r = dispatcher.call("nope.thing", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("unknown_method")
    end

    it "swallows V1 exceptions into code:'internal'" do
      allow(v1).to receive(:get_processes).and_raise(StandardError, "boom")
      r = dispatcher.call("processes.list", {})
      expect(r[:type]).to eq("error")
      expect(r[:payload][:code]).to eq("internal")
      expect(r[:payload][:message]).to include("boom")
    end
  end
end
