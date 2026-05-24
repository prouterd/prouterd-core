require "spec_helper"
require "json"
require "faye/websocket"

# Cover the bits of CliWebSocket the existing spec doesn't reach:
# the class-level `handle` entrypoint, the two rescue paths inside
# command.exec (ShellError + generic StandardError), and the
# send_raw rescue branch.
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

  before { described_class.reset_sessions! }
  after  { described_class.reset_sessions!; db.close }

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

      response = described_class.handle(env, session_id: "s1", store: store, admin_token: nil)

      expect(callbacks.keys).to match_array(%i[open message close])
      expect(response).to eq([101, {}, []])
    end
  end

  describe "command.exec rescue paths" do
    let(:conn) do
      described_class.new(socket, env: env, session_id: "shell-sid",
                                  store: store, admin_token: nil)
    end

    before { conn.on_open; socket.sent.clear }

    it "converts a Shell::ShellError into a stderr line with exit_code=1" do
      allow_any_instance_of(Prouterd::Shell::Shell).to receive(:execute_one)
        .and_raise(Prouterd::Shell::ShellError, "boom-shell")

      conn.on_message(JSON.dump(id: "c1", type: "command.exec",
                                payload: { command: "show running-config" }))
      msgs = socket.sent.map { |s| JSON.parse(s) }
      stderrs = msgs.select { |m| m["type"] == "command.output" && m.dig("payload", "stream") == "stderr" }
      done = msgs.last
      expect(stderrs.map { |m| m.dig("payload", "chunk") }).to include(/boom-shell/)
      expect(done["type"]).to eq("command.complete")
      expect(done.dig("payload", "exit_code")).to eq(1)
    end

    it "converts a generic StandardError into a stderr line with class name + exit_code=1" do
      allow_any_instance_of(Prouterd::Shell::Shell).to receive(:execute_one)
        .and_raise(RuntimeError, "kaboom")

      conn.on_message(JSON.dump(id: "c2", type: "command.exec",
                                payload: { command: "show running-config" }))
      msgs = socket.sent.map { |s| JSON.parse(s) }
      stderr_chunks = msgs.select { |m| m["type"] == "command.output" && m.dig("payload", "stream") == "stderr" }
                          .map { |m| m.dig("payload", "chunk") }
      done = msgs.last
      expect(stderr_chunks.join).to include("RuntimeError").and include("kaboom")
      expect(done.dig("payload", "exit_code")).to eq(1)
    end
  end

  describe "send_raw rescue" do
    it "swallows socket-send exceptions and logs them" do
      bad_socket = Class.new do
        def send(_); raise "explode"; end
        def close(*); end
      end.new
      logger = double("logger")
      expect(logger).to receive(:error).with(/send error/)
      conn = described_class.new(bad_socket, env: env, session_id: "x",
                                              store: store, admin_token: nil,
                                              logger: logger)
      expect { conn.on_open }.not_to raise_error
    end
  end

  describe "on_close" do
    it "is a no-op and does not raise" do
      conn = described_class.new(socket, env: env, session_id: "n",
                                          store: store, admin_token: nil)
      conn.on_open
      expect { conn.on_close }.not_to raise_error
    end
  end
end
