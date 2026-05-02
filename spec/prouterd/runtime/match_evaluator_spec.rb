require "spec_helper"

RSpec.describe Prouterd::Runtime::MatchEvaluator do
  def match(path, op, *vals)
    Prouterd::Config::AST::Match.new(path: path, operator: op, values: vals, line: 0)
  end

  let(:context) do
    Prouterd::Runtime::Context.new(
      "event"  => { "type" => "lead.created", "score" => 75 },
      "lead"   => {
        "region"  => "EU",
        "tags"    => ["a", "b"],
        "verified" => true
      }
    )
  end

  describe "eq" do
    it "matches strings" do
      expect(described_class.evaluate(match("event.type", "eq", "lead.created"), context)).to be(true)
      expect(described_class.evaluate(match("event.type", "eq", "other"), context)).to be(false)
    end

    it "matches integers" do
      expect(described_class.evaluate(match("event.score", "eq", 75), context)).to be(true)
      expect(described_class.evaluate(match("event.score", "eq", 74), context)).to be(false)
    end

    it "treats missing path as nil and rejects" do
      expect(described_class.evaluate(match("event.missing", "eq", "x"), context)).to be(false)
    end
  end

  describe "neq" do
    it "negates eq" do
      expect(described_class.evaluate(match("event.type", "neq", "x"), context)).to be(true)
      expect(described_class.evaluate(match("event.type", "neq", "lead.created"), context)).to be(false)
    end
  end

  describe "gt / gte / lt / lte" do
    it "compares integers" do
      expect(described_class.evaluate(match("event.score", "gt", 50), context)).to be(true)
      expect(described_class.evaluate(match("event.score", "gt", 75), context)).to be(false)
      expect(described_class.evaluate(match("event.score", "gte", 75), context)).to be(true)
      expect(described_class.evaluate(match("event.score", "lt", 100), context)).to be(true)
      expect(described_class.evaluate(match("event.score", "lte", 75), context)).to be(true)
    end

    it "returns false when value is missing" do
      expect(described_class.evaluate(match("missing.score", "gt", 0), context)).to be(false)
    end

    it "returns false on type-incompatible compare" do
      expect(described_class.evaluate(match("event.type", "gt", 0), context)).to be(false)
    end
  end

  describe "exists" do
    it "true for non-nil" do
      expect(described_class.evaluate(match("event.type", "exists"), context)).to be(true)
    end

    it "false for nil / missing" do
      expect(described_class.evaluate(match("event.missing", "exists"), context)).to be(false)
    end

    it "true for nested non-nil including arrays and booleans" do
      expect(described_class.evaluate(match("lead.tags", "exists"), context)).to be(true)
      expect(described_class.evaluate(match("lead.verified", "exists"), context)).to be(true)
    end
  end

  describe "in" do
    it "tests membership in a value list" do
      expect(described_class.evaluate(match("lead.region", "in", "US", "EU", "KZ"), context)).to be(true)
      expect(described_class.evaluate(match("lead.region", "in", "US", "AS"), context)).to be(false)
    end
  end

  describe "passes? (AND across matches)" do
    it "true when all match" do
      ms = [
        match("event.score", "gt", 50),
        match("lead.region", "in", "EU", "US")
      ]
      expect(described_class.passes?(ms, context)).to be(true)
    end

    it "false when any fails" do
      ms = [
        match("event.score", "gt", 50),
        match("lead.region", "eq", "US")
      ]
      expect(described_class.passes?(ms, context)).to be(false)
    end

    it "true when matches list is empty (unconditional route)" do
      expect(described_class.passes?([], context)).to be(true)
    end
  end

  describe "static_evaluate (for tracer)" do
    it "returns :runtime when path is under a runtime-only prefix" do
      result = described_class.static_evaluate(
        match("lead.scored.score", "gt", 70), context, runtime_paths: ["lead.scored"]
      )
      expect(result).to eq(:runtime)
    end

    it "returns true/false when path is statically resolvable" do
      result = described_class.static_evaluate(
        match("event.score", "gt", 70), context, runtime_paths: ["lead.scored"]
      )
      expect(result).to be(true)
    end
  end
end
