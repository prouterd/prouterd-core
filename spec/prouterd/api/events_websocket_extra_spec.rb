require "spec_helper"
require "json"
require "faye/websocket"

# Cover the tail of EventsWebSocket: the class-level `handle` entry
# point, the invalid-JSON / unknown-type / missing-topic-unsubscribe
# error paths, and the send_raw rescue.
RSpec.describe Prouterd::API::EventsWebSocket do
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

  def last_msg
    JSON.parse(socket.sent.last)
  end

  describe ".handle" do
    it "constructs a Faye::WebSocket, wires open/message/close, returns the rack response" do
      faye_double = double("FayeWebSocket")
      callbacks = {}
      allow(faye_double).to receive(:on) { |evt, &blk| callbacks[evt] = blk }
      allow(faye_double).to receive(:rack_response).and_return([101, {}, []])
      allow(Faye::WebSocket).to receive(:new).with(env).and_return(faye_double)

      result = described_class.handle(env, events: events, admin_token: nil)

      expect(callbacks.keys).to match_array(%i[open message close])
      expect(result).to eq([101, {}, []])
    end
  end

  describe "on_message error paths" do
    let(:conn) do
      described_class.new(socket, env: env, events: events, admin_token: nil)
    end

    before { conn.on_open; socket.sent.clear }

    it "returns an invalid_json error frame on garbage input" do
      conn.on_message("{not json")
      expect(last_msg["type"]).to eq("error")
      expect(last_msg.dig("payload", "code")).to eq("invalid_json")
    end

    it "returns an unknown_type error on an unrecognised frame type" do
      conn.on_message(JSON.dump(id: "x", type: "frobnicate"))
      expect(last_msg["type"]).to eq("error")
      expect(last_msg.dig("payload", "code")).to eq("unknown_type")
      expect(last_msg["reply_to"]).to eq("x")
    end

    it "errors when unsubscribe arrives without payload.topic" do
      conn.on_message(JSON.dump(id: "u1", type: "unsubscribe", payload: {}))
      expect(last_msg["type"]).to eq("error")
      expect(last_msg.dig("payload", "code")).to eq("invalid_payload")
      expect(last_msg["reply_to"]).to eq("u1")
    end
  end

  describe "send_raw rescue" do
    it "logs an error and does not raise when @socket.send blows up" do
      logger = double("logger")
      expect(logger).to receive(:error).with(/send error/)
      bad_socket = Class.new do
        def send(_); raise "boom"; end
        def close(*); end
      end.new
      bad_conn = described_class.new(bad_socket, env: env, events: events,
                                                  admin_token: nil, logger: logger)
      expect { bad_conn.on_open }.not_to raise_error
    end
  end

  describe "auth edge case for ws path" do
    it "send_error on unauth doesn't bomb if the socket has no #close" do
      no_close_socket = Class.new do
        attr_reader :sent
        def initialize; @sent = []; end
        def send(s); @sent << s; end
      end.new
      env["HTTP_AUTHORIZATION"] = "Bearer wrong"
      conn = described_class.new(no_close_socket, env: env, events: events,
                                                   admin_token: "right")
      expect { conn.on_open }.not_to raise_error
      expect(JSON.parse(no_close_socket.sent.first)["type"]).to eq("error")
    end

    it "accepts a valid cookie session even with no Authorization header" do
      allow(Prouterd::API::Auth).to receive(:cookie_session_valid?).and_return(true)
      conn = described_class.new(socket, env: {}, events: events,
                                          admin_token: "set-and-required")
      conn.on_open
      hello = JSON.parse(socket.sent.first)
      expect(hello["type"]).to eq("hello")
    end

    it "rejects when admin_token is set but no bearer is provided" do
      conn = described_class.new(socket, env: {}, events: events,
                                          admin_token: "expected")
      conn.on_open
      err = JSON.parse(socket.sent.first)
      expect(err.dig("payload", "code")).to eq("unauthorized")
    end
  end

  describe "internal-event routing skip-when-missing branches" do
    let(:conn) { described_class.new(socket, env: env, events: events, admin_token: nil) }
    before { conn.on_open }

    it "route_run is a no-op when payload has no :run" do
      events.publish(:run_created, {}) # no :run key
      # no subscribed topic → still expect no run-related frame even
      # if a topic WERE subscribed. The early return short-circuits.
      run_frames = socket.sent.map { |s| JSON.parse(s) }.select { |m| m.dig("payload", "uid") }
      expect(run_frames).to be_empty
    end

    it "route_step is a no-op when payload has no :step or no :run_uid" do
      events.publish(:step_created, {}) # no :step, no :run_uid
      events.publish(:step_created, { step: double }) # :step but no :run_uid
      step_frames = socket.sent.map { |s| JSON.parse(s) }
                          .select { |m| m["type"]&.start_with?("step.") }
      expect(step_frames).to be_empty
    end

    it "route_log is a no-op when payload has no :run_uid" do
      events.publish(:log_appended, { stream: "stdout", content: "x" })
      log_frames = socket.sent.map { |s| JSON.parse(s) }
                          .select { |m| m["type"] == "log.appended" }
      expect(log_frames).to be_empty
    end
  end

  describe "send_raw rescue when @logger is nil" do
    it "swallows the exception silently" do
      bad_socket = Class.new do
        def send(_); raise "kaboom"; end
        def close(*); end
      end.new
      conn = described_class.new(bad_socket, env: env, events: events,
                                              admin_token: nil) # no logger
      expect { conn.on_open }.not_to raise_error
    end
  end
end
