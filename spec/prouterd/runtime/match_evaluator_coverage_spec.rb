require "spec_helper"

RSpec.describe Prouterd::Runtime::MatchEvaluator do
  def match(path, op, *vals)
    Prouterd::Config::AST::Match.new(path: path, operator: op, values: vals, line: 0)
  end

  let(:context) do
    Prouterd::Runtime::Context.new("event" => { "type" => "x" })
  end

  describe "#evaluate" do
    it "raises ArgumentError for an unknown operator (else branch)" do
      expect {
        described_class.evaluate(match("event.type", "wat", "x"), context)
      }.to raise_error(ArgumentError, /unknown match operator/)
    end
  end

  describe ".static_evaluate" do
    it "returns :runtime when evaluate raises (rescue branch)" do
      bad_match = match("event.type", "wat", "x") # unknown op -> raises
      result = described_class.static_evaluate(bad_match, context, runtime_paths: [])
      expect(result).to eq(:runtime)
    end
  end

  describe ".numeric_compare" do
    it "returns nil if either side is nil" do
      expect(described_class.numeric_compare(nil, 1)).to be_nil
      expect(described_class.numeric_compare(1, nil)).to be_nil
    end

    it "returns nil for type-incomparable pairs" do
      expect(described_class.numeric_compare("hi", 1)).to be_nil
    end

    it "returns -1 / 0 / 1 for normal numeric compares" do
      expect(described_class.numeric_compare(1, 2)).to eq(-1)
      expect(described_class.numeric_compare(2, 2)).to eq(0)
      expect(described_class.numeric_compare(3, 2)).to eq(1)
    end
  end
end
