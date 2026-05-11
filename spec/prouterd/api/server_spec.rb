require "spec_helper"

RSpec.describe Prouterd::API::Server do
  # Most of Server is "spin up Puma and block until SIGINT" — covered by
  # the daemon smoke tests under examples/. These specs pin the
  # initialization contract: defaults, kwargs validation, SSL gating,
  # stop()'s pipe wakeup, drain math.

  let(:app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] } }

  describe "constructor defaults" do
    it "exposes the constants the daemon CLI prints in its help text" do
      expect(described_class::DEFAULT_BIND).to eq("127.0.0.1")
      expect(described_class::DEFAULT_PORT).to eq(8080)
      expect(described_class::DEFAULT_DRAIN_TIMEOUT).to eq(30)
    end

    it "coerces port to an Integer" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: "9090")
      expect(s.port).to eq(9090)
      expect(s.port).to be_a(Integer)
    end

    it "raises on non-integer port" do
      expect {
        described_class.new(app: app, bind: "0.0.0.0", port: "nope")
      }.to raise_error(ArgumentError)
    end
  end

  describe "ssl gating" do
    it "drops blank-string SSL cert/key so empty env vars don't enable TLS by accident" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: 8080,
                              ssl_cert: "", ssl_key: "")
      expect(s.instance_variable_get(:@ssl_cert)).to be_nil
      expect(s.instance_variable_get(:@ssl_key)).to be_nil
    end

    it "keeps non-empty SSL cert/key" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: 8080,
                              ssl_cert: "/etc/prouterd/cert.pem",
                              ssl_key:  "/etc/prouterd/key.pem")
      expect(s.instance_variable_get(:@ssl_cert)).to eq("/etc/prouterd/cert.pem")
      expect(s.instance_variable_get(:@ssl_key)).to  eq("/etc/prouterd/key.pem")
    end

    it "drops non-string types defensively" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: 8080,
                              ssl_cert: 12345, ssl_key: false)
      expect(s.instance_variable_get(:@ssl_cert)).to be_nil
      expect(s.instance_variable_get(:@ssl_key)).to  be_nil
    end
  end

  describe "#stop" do
    it "writes a single byte to the stop pipe so the blocking read in #run wakes up" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: 0)
      reader = s.instance_variable_get(:@stop_pipe_r)
      s.stop
      expect(IO.select([reader], nil, nil, 0.1)).not_to be_nil
      expect(reader.read(1)).to eq("x")
    end

    it "swallows write errors so a second stop() can't crash the daemon" do
      s = described_class.new(app: app, bind: "0.0.0.0", port: 0)
      s.instance_variable_get(:@stop_pipe_w).close
      expect { s.stop }.not_to raise_error
    end
  end

  describe "#drain_in_flight" do
    let(:logger) do
      double("logger").tap do |l|
        allow(l).to receive(:info)
        allow(l).to receive(:warn)
        allow(l).to receive(:notice)
      end
    end

    it "returns immediately when in-flight count is zero" do
      registry = instance_double("InFlightRegistry", in_flight_count: 0)
      s = described_class.new(app: app, bind: "0.0.0.0", port: 0,
                              in_flight: registry, drain_timeout: 5, logger: logger)
      start = Time.now
      s.send(:drain_in_flight)
      expect(Time.now - start).to be < 0.5
    end

    it "warns and breaks once the drain deadline passes" do
      registry = instance_double("InFlightRegistry",
                                 in_flight_count: 2,
                                 in_flight_uids: %w[run_a run_b])
      s = described_class.new(app: app, bind: "0.0.0.0", port: 0,
                              in_flight: registry, drain_timeout: 0.05, logger: logger)
      expect(logger).to receive(:warn) do |_msg, **kw|
        expect(kw[:facility]).to eq("DAEMON")
        expect(kw[:mnemonic]).to eq("DRAIN_TIMEOUT")
        expect(kw[:remaining]).to eq(2)
        expect(kw[:run_uids]).to eq("run_a,run_b")
      end
      s.send(:drain_in_flight)
    end
  end
end
