require "spec_helper"
require "json"

RSpec.describe Prouterd::API::CliWebSocket do
  let(:db)    { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }

  let(:socket) do
    Class.new do
      attr_reader :sent, :closed_with
      def initialize; @sent = []; end
      def send(s); @sent << s; end
      def close(code, reason); @closed_with = [code, reason]; end
    end.new
  end

  let(:env) { {} }

  subject(:conn) do
    described_class.new(socket, env: env, session_id: "session-1",
                                store: store, admin_token: nil)
  end

  before  { described_class.reset_sessions! }
  after   { described_class.reset_sessions!; db.close }

  def last_msg
    JSON.parse(socket.sent.last)
  end

  describe "#on_open" do
    it "creates a fresh session and announces hello + initial prompt" do
      conn.on_open
      expect(last_msg["type"]).to eq("hello")
      expect(last_msg.dig("payload", "session_id")).to eq("session-1")
      expect(last_msg.dig("payload", "prompt")).to match(/[#] $/)
    end

    it "rejects bad bearer when admin_token configured" do
      env["HTTP_AUTHORIZATION"] = "Bearer wrong"
      bad = described_class.new(socket, env: env, session_id: "x", store: store, admin_token: "right")
      bad.on_open
      expect(JSON.parse(socket.sent.first)["type"]).to eq("error")
      expect(socket.closed_with).to eq([4401, "unauthorized"])
    end

    it "accepts the bearer via ?token= query parameter (browser fallback)" do
      env["QUERY_STRING"] = "token=right"
      good = described_class.new(socket, env: env, session_id: "y", store: store, admin_token: "right")
      good.on_open
      expect(last_msg["type"]).to eq("hello")
    end
  end

  describe "command.exec" do
    before { conn.on_open; socket.sent.clear }

    it "executes a real shell command and emits output + complete frames" do
      conn.on_message(JSON.dump(id: "c1", type: "command.exec",
                                payload: { command: "show running-config" }))
      msgs    = socket.sent.map { |s| JSON.parse(s) }
      outputs = msgs.select { |m| m["type"] == "command.output" }
      done    = msgs.last

      expect(outputs).not_to be_empty
      expect(outputs.first.dig("payload", "stream")).to eq("stdout")
      expect(done["type"]).to eq("command.complete")
      expect(done["reply_to"]).to eq("c1")
      expect(done.dig("payload", "exit_code")).to eq(0)
      expect(done.dig("payload", "prompt")).to match(/[#] $/)
    end

    it "validates payload" do
      conn.on_message(JSON.dump(id: "c1", type: "command.exec", payload: {}))
      err = last_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("invalid_payload")
    end

    it "stderr surfaces with stream=stderr on bogus commands" do
      conn.on_message(JSON.dump(id: "c2", type: "command.exec",
                                payload: { command: "definitely_not_a_command" }))
      msgs = socket.sent.map { |s| JSON.parse(s) }
      streams = msgs.select { |m| m["type"] == "command.output" }
                    .map    { |m| m.dig("payload", "stream") }
      expect(streams).to include("stderr")

      done = msgs.find { |m| m["type"] == "command.complete" }
      expect(done.dig("payload", "exit_code")).to eq(1)
    end
  end

  describe "session persistence" do
    it "shares the same Session across multiple connections with the same id" do
      a_socket = socket
      a_conn   = conn
      a_conn.on_open
      # Run an `enable` to advance the mode-stack into Privileged.
      a_conn.on_message(JSON.dump(id: "c1", type: "command.exec", payload: { command: "enable" }))
      a_conn.on_close

      # New connection, same session_id — should resume in privileged mode.
      b_socket = Class.new do
        attr_reader :sent
        def initialize; @sent = []; end
        def send(s); @sent << s; end
        def close(*); end
      end.new
      b_conn = described_class.new(b_socket, env: env, session_id: "session-1",
                                              store: store, admin_token: nil)
      b_conn.on_open
      hello = JSON.parse(b_socket.sent.first)
      expect(hello.dig("payload", "prompt")).to match(/#\s*\z/)
    end
  end

  describe "ping / pong" do
    before { conn.on_open; socket.sent.clear }

    it "responds with pong" do
      conn.on_message(JSON.dump(id: "p1", type: "ping"))
      expect(last_msg["type"]).to eq("pong")
      expect(last_msg["reply_to"]).to eq("p1")
    end
  end

  describe "invalid input" do
    before { conn.on_open; socket.sent.clear }

    it "errors on JSON parse failure" do
      conn.on_message("not json")
      expect(last_msg["type"]).to eq("error")
      expect(last_msg.dig("payload", "code")).to eq("invalid_json")
    end

    it "errors on unknown type" do
      conn.on_message(JSON.dump(id: "x", type: "frobnicate"))
      expect(last_msg.dig("payload", "code")).to eq("unknown_type")
    end
  end
end
