require "spec_helper"
require "puma"
require "puma/server"

# Pin down the parts of Prouterd::API::Server that the smoke-only spec
# can't reach: the actual `run` flow (Puma stub), SSL listener wiring,
# signal handler installation with ArgumentError fallback, and one drain
# tick at a time so we don't have to wait on real wall-clock sleeps.
RSpec.describe Prouterd::API::Server do
  let(:rack_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] } }
  let(:logger) do
    double("logger").tap do |l|
      allow(l).to receive(:info)
      allow(l).to receive(:warn)
      allow(l).to receive(:notice)
      allow(l).to receive(:error)
    end
  end

  # Fake Puma::Server: records what was wired up; never binds a real port.
  let(:puma_double) do
    Class.new do
      attr_reader :added_tcp, :added_ssl, :ran, :stopped_with
      def initialize; @added_tcp = []; @added_ssl = []; end
      def add_tcp_listener(host, port); @added_tcp << [host, port]; end
      def add_ssl_listener(host, port, ctx); @added_ssl << [host, port, ctx]; end
      def run; @ran = true; end
      def stop(force = false); @stopped_with = force; end
    end.new
  end

  before { allow(Puma::Server).to receive(:new).and_return(puma_double) }

  describe "Server.run convenience constructor" do
    it "forwards to a fresh instance and yields the started server" do
      yielded = nil
      Prouterd::API::Server.run(
        app: rack_app, bind: "127.0.0.1", port: 0, logger: logger
      ) do |srv|
        yielded = srv
        srv.stop                  # release the blocking pipe-read
      end
      expect(yielded).to be_a(described_class)
      expect(puma_double.ran).to be(true)
      expect(puma_double.stopped_with).to be(true)
    end
  end

  describe "#run plain TCP path" do
    it "wires the TCP listener and logs the http URL" do
      srv = described_class.new(app: rack_app, bind: "127.0.0.1", port: 8081, logger: logger)
      expect(logger).to receive(:info).with(
        "listening",
        hash_including(facility: "DAEMON", mnemonic: "LISTENING", url: "http://127.0.0.1:8081")
      )
      Thread.new { sleep 0.05; srv.stop }
      srv.run
      expect(puma_double.added_tcp).to eq([["127.0.0.1", 8081]])
      expect(puma_double.added_ssl).to be_empty
      expect(puma_double.stopped_with).to be(true)
    end

    it "stops accepting on the app and drains in-flight when configured" do
      app_dbl = double("app")
      allow(app_dbl).to receive(:stop_accepting)
      registry = instance_double("InFlightRegistry", in_flight_count: 0)
      srv = described_class.new(
        app: app_dbl, bind: "127.0.0.1", port: 0,
        logger: logger, in_flight: registry, drain_timeout: 1
      )
      Thread.new { sleep 0.05; srv.stop }
      expect(app_dbl).to receive(:stop_accepting)
      srv.run
    end
  end

  describe "#run SSL path" do
    it "wires the SSL listener with a configured Puma::MiniSSL::Context" do
      require "puma/minissl"
      ctx_dbl = instance_double(Puma::MiniSSL::Context)
      allow(ctx_dbl).to receive(:cert=)
      allow(ctx_dbl).to receive(:key=)
      allow(Puma::MiniSSL::Context).to receive(:new).and_return(ctx_dbl)

      srv = described_class.new(
        app: rack_app, bind: "127.0.0.1", port: 4443,
        logger: logger,
        ssl_cert: "/etc/cert.pem", ssl_key: "/etc/key.pem"
      )
      expect(ctx_dbl).to receive(:cert=).with("/etc/cert.pem")
      expect(ctx_dbl).to receive(:key=).with("/etc/key.pem")
      expect(logger).to receive(:info).with(
        "listening (TLS)",
        hash_including(facility: "DAEMON", mnemonic: "LISTENING",
                       url: "https://127.0.0.1:4443", cert: "/etc/cert.pem")
      )
      Thread.new { sleep 0.05; srv.stop }
      srv.run
      expect(puma_double.added_ssl).to eq([["127.0.0.1", 4443, ctx_dbl]])
      expect(puma_double.added_tcp).to be_empty
    end
  end

  describe "#drain_tick" do
    let(:registry) { double("InFlightRegistry") }
    let(:srv) do
      described_class.new(app: rack_app, bind: "0.0.0.0", port: 0,
                          logger: logger, in_flight: registry, drain_timeout: 5)
    end

    it "returns :done when nothing is in flight" do
      allow(registry).to receive(:in_flight_count).and_return(0)
      expect(srv.send(:drain_tick, now: Time.now, deadline: Time.now + 10)).to eq(:done)
    end

    it "returns :timed_out and warns when deadline has passed" do
      allow(registry).to receive(:in_flight_count).and_return(2)
      allow(registry).to receive(:in_flight_uids).and_return(%w[run_x run_y])
      expect(logger).to receive(:warn).with(
        "drain timed out",
        hash_including(facility: "DAEMON", mnemonic: "DRAIN_TIMEOUT",
                       remaining: 2, run_uids: "run_x,run_y")
      )
      result = srv.send(:drain_tick, now: Time.at(100), deadline: Time.at(99))
      expect(result).to eq(:timed_out)
    end

    it "returns :continue and emits the 5-second info log on multiple-of-5 wall clocks" do
      allow(registry).to receive(:in_flight_count).and_return(3)
      expect(logger).to receive(:info).with(
        "draining in-flight runs",
        hash_including(facility: "DAEMON", mnemonic: "DRAINING", remaining: 3)
      )
      result = srv.send(:drain_tick, now: Time.at(100), deadline: Time.at(200))
      expect(result).to eq(:continue)
    end

    it "returns :continue silently on a non-multiple-of-5 second" do
      allow(registry).to receive(:in_flight_count).and_return(1)
      expect(logger).not_to receive(:info)
      result = srv.send(:drain_tick, now: Time.at(101), deadline: Time.at(200))
      expect(result).to eq(:continue)
    end
  end

  describe "#trap_signal" do
    let(:srv) { described_class.new(app: rack_app, bind: "0.0.0.0", port: 0, logger: logger) }

    it "installs a trap that fires stop() when the signal arrives" do
      captured = nil
      allow(Signal).to receive(:trap).with("INT") do |sig, &blk|
        captured = blk
      end
      srv.send(:trap_signal, "INT")
      expect(captured).to be_a(Proc)
      # Invoking the trap proc should call stop on the server.
      expect(srv).to receive(:stop)
      captured.call
    end

    it "swallows ArgumentError from Signal.trap (unsupported platform)" do
      allow(Signal).to receive(:trap).with("INT").and_raise(ArgumentError)
      expect { srv.send(:trap_signal, "INT") }.not_to raise_error
    end
  end
end
