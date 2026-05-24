require "spec_helper"

RSpec.describe Prouterd::Iface::PostgresCaller do
  let(:caller) { described_class.new }

  describe ".pg_available?" do
    it "returns true when require succeeds" do
      allow(described_class).to receive(:require).with("pg").and_return(true)
      expect(described_class.pg_available?).to be(true)
    end

    it "returns false when require raises LoadError" do
      allow(described_class).to receive(:require).with("pg").and_raise(LoadError)
      expect(described_class.pg_available?).to be(false)
    end
  end

  describe "missing dependency" do
    it "returns missing_dependency envelope when pg gem is not loaded" do
      allow(described_class).to receive(:pg_available?).and_return(false)
      result = caller.run(double(field: nil))
      expect(result.error_type).to eq("missing_dependency")
    end
  end

  describe "#parse_params" do
    it "returns [] for nil and empty input" do
      expect(caller.send(:parse_params, nil)).to eq([])
      expect(caller.send(:parse_params, "")).to eq([])
    end

    it "returns the value verbatim when already an Array" do
      expect(caller.send(:parse_params, ["a", "b"])).to eq(["a", "b"])
    end

    it "splits a comma-separated list" do
      expect(caller.send(:parse_params, "a, b, c")).to eq(["a", "b", "c"])
    end

    it "preserves commas inside quoted values" do
      expect(caller.send(:parse_params, %q("Doe, John",42))).to eq(["Doe, John", "42"])
    end

    it "honors backslash escapes inside a quoted value" do
      expect(caller.send(:parse_params, %q("she said \"hi\"",42))).to eq(['she said "hi"', "42"])
    end
  end

  describe "#parse_int" do
    it "returns default when value is nil" do
      expect(caller.send(:parse_int, nil, 5)).to eq(5)
    end

    it "returns default for empty value" do
      expect(caller.send(:parse_int, "", 5)).to eq(5)
    end

    it "parses an integer string" do
      expect(caller.send(:parse_int, "42", nil)).to eq(42)
    end

    it "returns default when not parseable" do
      expect(caller.send(:parse_int, "abc", :fallback)).to eq(:fallback)
    end
  end

  describe "#error" do
    it "builds an error envelope" do
      e = caller.send(:error, "x", "msg")
      expect(e[:error_type]).to eq("x")
      expect(e[:error_message]).to eq("msg")
      expect(e[:exit_code]).to be_nil
    end
  end

  describe "perform_run guards" do
    before { allow(described_class).to receive(:pg_available?).and_return(true) }

    it "errors when dsn is missing" do
      req = double(field: "")
      allow(req).to receive(:field).with("dsn").and_return("")
      allow(req).to receive(:field).with("query").and_return("SELECT 1")
      allow(req).to receive(:field).with("params").and_return(nil)
      allow(req).to receive(:field).with("statement-timeout").and_return(nil)
      result = caller.run(req)
      expect(result.error_type).to eq("invalid_interface")
    end

    it "errors when query is missing" do
      req = double
      allow(req).to receive(:field).with("dsn").and_return("postgres://x")
      allow(req).to receive(:field).with("query").and_return("")
      allow(req).to receive(:field).with("params").and_return(nil)
      allow(req).to receive(:field).with("statement-timeout").and_return(nil)
      result = caller.run(req)
      expect(result.error_type).to eq("invalid_call")
    end

    it "wraps unexpected StandardError into postgres_error" do
      req = double
      allow(req).to receive(:field).with("dsn").and_return("postgres://x")
      allow(req).to receive(:field).with("query").and_return("SELECT 1")
      allow(req).to receive(:field).with("params").and_return(nil)
      allow(req).to receive(:field).with("statement-timeout").and_return(nil)
      stub_const("PG", Class.new { def self.connect(_); raise StandardError, "exploded"; end })
      result = caller.run(req)
      expect(result.error_type).to eq("postgres_error")
      expect(result.error_message).to include("exploded")
    end
  end
end
