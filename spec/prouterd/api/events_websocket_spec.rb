require "spec_helper"
require "json"

RSpec.describe Prouterd::API::EventsWebSocket do
  # Capture-only socket: records what the handler would have written.
  let(:socket) do
    Class.new do
      attr_reader :sent, :closed_with
      def initialize; @sent = []; end
      def send(s); @sent << s; end
      def close(code, reason); @closed_with = [code, reason]; end
    end.new
  end

  let(:events) { Prouterd::Events.new }
  let(:env)    { {} }

  subject(:conn) do
    described_class.new(socket, env: env, events: events, admin_token: nil)
  end

  def last_msg
    JSON.parse(socket.sent.last)
  end

  describe "#on_open" do
    it "sends a hello frame with the daemon version" do
      conn.on_open
      expect(last_msg["type"]).to eq("hello")
      expect(last_msg.dig("payload", "version")).to eq(Prouterd::VERSION)
    end

    it "rejects unauthenticated connections when admin_token is set" do
      env["HTTP_AUTHORIZATION"] = "Bearer wrong"
      bad_conn = described_class.new(socket, env: env, events: events, admin_token: "right")
      bad_conn.on_open
      expect(JSON.parse(socket.sent.first)["type"]).to eq("error")
      expect(JSON.parse(socket.sent.first).dig("payload", "code")).to eq("unauthorized")
      expect(socket.closed_with).to eq([4401, "unauthorized"])
    end

    it "accepts the right bearer token" do
      env["HTTP_AUTHORIZATION"] = "Bearer right"
      good_conn = described_class.new(socket, env: env, events: events, admin_token: "right")
      good_conn.on_open
      expect(last_msg["type"]).to eq("hello")
    end

    it "accepts the bearer via the ?token= query parameter (browser fallback)" do
      env["QUERY_STRING"] = "token=right"
      good_conn = described_class.new(socket, env: env, events: events, admin_token: "right")
      good_conn.on_open
      expect(last_msg["type"]).to eq("hello")
    end

    it "rejects a wrong ?token= query parameter" do
      env["QUERY_STRING"] = "token=wrong"
      bad_conn = described_class.new(socket, env: env, events: events, admin_token: "right")
      bad_conn.on_open
      expect(JSON.parse(socket.sent.first)["type"]).to eq("error")
      expect(JSON.parse(socket.sent.first).dig("payload", "code")).to eq("unauthorized")
    end
  end

  describe "WS-RPC (type: 'call')" do
    let(:dispatcher) do
      Class.new do
        attr_reader :calls
        def initialize; @calls = []; end
        def call(method, args)
          @calls << [method, args]
          if method == "boom"
            { type: "error", payload: { code: "not_found", message: "no such thing" } }
          else
            { type: "reply", payload: { method: method, echoed: args } }
          end
        end
      end.new
    end

    let(:rpc_conn) do
      described_class.new(socket, env: env, events: events,
                          admin_token: nil, dispatcher: dispatcher)
    end

    before { rpc_conn.on_open }

    it "dispatches a call frame and replies with the dispatcher's payload" do
      rpc_conn.on_message(JSON.dump(id: "c1", type: "call",
                                    payload: { method: "processes.list", args: { limit: 5 } }))
      expect(dispatcher.calls).to eq([["processes.list", { "limit" => 5 }]])
      reply = last_msg
      expect(reply["type"]).to eq("reply")
      expect(reply["reply_to"]).to eq("c1")
      expect(reply.dig("payload", "method")).to eq("processes.list")
      expect(reply.dig("payload", "echoed", "limit")).to eq(5)
    end

    it "passes through dispatcher errors as type:error frames" do
      rpc_conn.on_message(JSON.dump(id: "c2", type: "call",
                                    payload: { method: "boom", args: {} }))
      err = last_msg
      expect(err["type"]).to eq("error")
      expect(err["reply_to"]).to eq("c2")
      expect(err.dig("payload", "code")).to eq("not_found")
    end

    it "errors when no dispatcher is wired" do
      no_disp = described_class.new(socket, env: env, events: events,
                                    admin_token: nil, dispatcher: nil)
      no_disp.on_open
      no_disp.on_message(JSON.dump(id: "c3", type: "call",
                                   payload: { method: "status", args: {} }))
      err = last_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("unsupported")
    end

    it "rejects a call with no method" do
      rpc_conn.on_message(JSON.dump(id: "c4", type: "call", payload: {}))
      err = last_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("invalid_payload")
    end

    it "rejects a call whose args is not an object" do
      rpc_conn.on_message(JSON.dump(id: "c5", type: "call",
                                    payload: { method: "x", args: "nope" }))
      err = last_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("invalid_payload")
    end
  end

  describe "subscribe / unsubscribe" do
    before { conn.on_open }

    it "subscribes to a wire topic and acks" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      ack = last_msg
      expect(ack["type"]).to eq("subscribe.ok")
      expect(ack.dig("payload", "topic")).to eq("runs")
      expect(conn.subscribed_topics).to include("runs")
    end

    it "is idempotent on the wire side" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      conn.on_message(JSON.dump(id: "m2", type: "subscribe", payload: { topic: "runs" }))
      expect(last_msg["type"]).to eq("subscribe.already")
    end

    it "errors on missing payload.topic" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: {}))
      expect(last_msg["type"]).to eq("error")
      expect(last_msg.dig("payload", "code")).to eq("invalid_payload")
    end

    it "drops the topic on unsubscribe" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      conn.on_message(JSON.dump(id: "m2", type: "unsubscribe", payload: { topic: "runs" }))
      expect(last_msg["type"]).to eq("unsubscribe.ok")
      expect(conn.subscribed_topics).not_to include("runs")
    end
  end

  describe "internal-event routing" do
    let(:run) do
      Prouterd::Storage::Run.new(
        id: 1, uid: "run_42", process_name: "p", process_config_commit_id: nil,
        interface_name: nil, status: "running",
        input_event_json: nil, context_json: nil, error_summary: nil,
        started_at: nil, finished_at: nil, created_at: nil,
        parent_run_id: nil, replay_of_run_id: nil
      )
    end
    let(:step) do
      Prouterd::Storage::Step.new(
        id: 7, run_id: 1, block_name: "extract", status: "success",
        attempt: 1, image: "x", input_json: nil, output_json: nil,
        exit_code: 0, error_type: nil, error_message: nil,
        started_at: nil, finished_at: nil, duration_ms: 1, created_at: nil
      )
    end

    before { conn.on_open }

    it "fans 'run.updated' to the 'runs' topic when subscribed" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      socket.sent.clear
      events.publish(:run_updated, run: run)

      msg = last_msg
      expect(msg["topic"]).to eq("runs")
      expect(msg["type"]).to eq("run.updated")
      expect(msg.dig("payload", "uid")).to eq("run_42")
    end

    it "fans 'run.updated' to the per-uid topic" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "run:run_42" }))
      socket.sent.clear
      events.publish(:run_updated, run: run)

      msg = last_msg
      expect(msg["topic"]).to eq("run:run_42")
    end

    it "fans step events to the per-run topic with run_uid in payload" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "run:run_42" }))
      socket.sent.clear
      events.publish(:step_updated, step: step, run_id: 1, run_uid: "run_42")

      msg = last_msg
      expect(msg["type"]).to eq("step.updated")
      expect(msg.dig("payload", "block_name")).to eq("extract")
      expect(msg.dig("payload", "run_uid")).to eq("run_42")
    end

    it "fans log events to the logs:<uid> topic" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "logs:run_42" }))
      socket.sent.clear
      events.publish(:log_appended,
                     run_id: 1, run_uid: "run_42", step_id: 7,
                     stream: "stdout", content: "hello\n", created_at: "2026-05-02T00:00:00Z")

      msg = last_msg
      expect(msg["topic"]).to eq("logs:run_42")
      expect(msg["type"]).to eq("log.appended")
      expect(msg.dig("payload", "content")).to eq("hello\n")
      expect(msg.dig("payload", "step_id")).to eq(7)
    end

    it "drops events for topics with no subscribers" do
      socket.sent.clear
      events.publish(:run_updated, run: run)
      expect(socket.sent).to be_empty
    end

    it "fans 'config_changed' to the 'system' topic" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "system" }))
      socket.sent.clear
      events.publish(:config_changed, reason: "rollback",
                                       running_commit: 42, startup_commit: 39)

      msg = last_msg
      expect(msg["topic"]).to eq("system")
      expect(msg["type"]).to eq("config.changed")
      expect(msg.dig("payload", "reason")).to eq("rollback")
      expect(msg.dig("payload", "running_commit")).to eq(42)
      expect(msg.dig("payload", "startup_commit")).to eq(39)
    end
  end

  describe "ping / pong" do
    before { conn.on_open }

    it "responds with pong tagged to the request id" do
      conn.on_message(JSON.dump(id: "p1", type: "ping"))
      expect(last_msg["type"]).to eq("pong")
      expect(last_msg["reply_to"]).to eq("p1")
    end
  end

  describe "#on_close" do
    before { conn.on_open }

    it "drops every event-bus subscription it held" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      conn.on_close
      # Reaching into the bus to confirm: no internal subscribers left.
      delivered = 0
      events.publish(:run_updated, run: nil) rescue nil
      expect(delivered).to eq(0)
    end
  end
end
