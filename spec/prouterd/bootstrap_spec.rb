require "spec_helper"
require "stringio"
require "tempfile"
require "prouterd/bootstrap"

RSpec.describe Prouterd::Bootstrap do
  let(:host_class) do
    Class.new do
      include Prouterd::Bootstrap

      attr_accessor :stderr

      def initialize
        @stderr = StringIO.new
      end
    end
  end

  let(:host) { host_class.new }

  describe "#default_runner_kind" do
    it "returns docker when PROUTERD_RUNNER is unset" do
      original = ENV.delete("PROUTERD_RUNNER")
      expect(host.default_runner_kind).to eq("docker")
    ensure
      ENV["PROUTERD_RUNNER"] = original if original
    end

    it "returns the env var when set" do
      ENV["PROUTERD_RUNNER"] = "stub"
      expect(host.default_runner_kind).to eq("stub")
    ensure
      ENV.delete("PROUTERD_RUNNER")
    end
  end

  describe "#open_store" do
    it "returns nil when no_db is true" do
      expect(host.open_store(nil, true)).to be_nil
    end

    it "returns a ConfigStore for a usable path" do
      Tempfile.create(["bs", ".sqlite3"]) do |tmp|
        tmp.close
        store = host.open_store(tmp.path, false)
        expect(store).to be_a(Prouterd::ControlPlane::ConfigStore)
        store.db.close
      end
    end

    it "returns :error and writes a stderr line when the underlying DB.open raises" do
      allow(Prouterd::Storage::DB).to receive(:open).and_raise(
        Prouterd::Storage::StorageError, "disk down"
      )
      result = host.open_store("/tmp/whatever.sqlite3", false)
      expect(result).to eq(:error)
      expect(host.stderr.string).to include("cannot open DB")
      expect(host.stderr.string).to include("disk down")
    end
  end

  describe "#build_runner" do
    it "returns CallRunner for nil/real/docker/shell" do
      [nil, "real", "docker", "shell"].each do |kind|
        expect(host.build_runner(kind)).to be_a(Prouterd::Runner::CallRunner)
      end
    end

    it "returns StubRunner for stub" do
      expect(host.build_runner("stub")).to be_a(Prouterd::Runner::StubRunner)
    end

    it "returns :error and writes a stderr line for an unknown kind" do
      result = host.build_runner("flamingo")
      expect(result).to eq(:error)
      expect(host.stderr.string).to include("unknown runner kind 'flamingo'")
    end

    it "returns :error and writes a stderr line on initialization failure" do
      allow(Prouterd::Runner::CallRunner).to receive(:new).and_raise(LoadError, "bad gem")
      result = host.build_runner("docker")
      expect(result).to eq(:error)
      expect(host.stderr.string).to include("cannot initialize runner")
    end
  end
end
