require "spec_helper"

RSpec.describe Prouterd::Runtime::ContractValidator do
  describe "Violation#to_s" do
    it "includes the detail when present" do
      v = described_class::Violation.new(path: "a.b", kind: :wrong_type, detail: "expected integer, got string")
      expect(v.to_s).to eq("a.b: wrong_type (expected integer, got string)")
    end

    it "omits parentheses when detail is nil" do
      v = described_class::Violation.new(path: "a.b", kind: :missing, detail: nil)
      expect(v.to_s).to eq("a.b: missing")
    end
  end

  describe ".type_match?" do
    it "matches every supported type kind correctly" do
      expect(described_class.type_match?(1,        "integer")).to be(true)
      expect(described_class.type_match?(1.5,      "number")).to be(true)
      expect(described_class.type_match?("hi",     "string")).to be(true)
      expect(described_class.type_match?(true,     "boolean")).to be(true)
      expect(described_class.type_match?(false,    "boolean")).to be(true)
      expect(described_class.type_match?([],       "array")).to be(true)
      expect(described_class.type_match?({},       "object")).to be(true)
    end

    it "rejects mismatches per type" do
      expect(described_class.type_match?("1",   "integer")).to be(false)
      expect(described_class.type_match?("hi",  "number")).to be(false)
      expect(described_class.type_match?(42,    "string")).to be(false)
      expect(described_class.type_match?("yes", "boolean")).to be(false)
      expect(described_class.type_match?({},    "array")).to be(false)
      expect(described_class.type_match?([],    "object")).to be(false)
    end

    it "returns true for any unknown type (else branch)" do
      expect(described_class.type_match?("anything", "unknown_type")).to be(true)
    end
  end

  describe ".ruby_type_name" do
    it "returns the friendly name per Ruby class" do
      expect(described_class.ruby_type_name(1)).to     eq("integer")
      expect(described_class.ruby_type_name(1.5)).to   eq("number")
      expect(described_class.ruby_type_name("x")).to   eq("string")
      expect(described_class.ruby_type_name(true)).to  eq("boolean")
      expect(described_class.ruby_type_name(false)).to eq("boolean")
      expect(described_class.ruby_type_name([])).to    eq("array")
      expect(described_class.ruby_type_name({})).to    eq("object")
      expect(described_class.ruby_type_name(nil)).to   eq("null")
      expect(described_class.ruby_type_name(:sym)).to  eq("symbol") # else branch
    end
  end

  describe ".format_match?" do
    it "returns true for unknown format names (else branch)" do
      expect(described_class.format_match?("anything", "weird-unknown-format")).to be(true)
    end
  end

  describe ".dig" do
    it "stops walking when an intermediate node is not a Hash (line 117 break)" do
      # `break nil` exits the each early; `node` is the last value reached
      # before the break, so we get the non-Hash node itself back.
      payload = { "a" => [1, 2, 3] }
      expect(described_class.dig(payload, "a.b.c")).to eq([1, 2, 3])
    end

    it "returns the leaf value for a valid dotted path" do
      expect(described_class.dig({ "a" => { "b" => 42 } }, "a.b")).to eq(42)
    end
  end

  describe "invalid regex pattern surfaces :invalid_pattern" do
    let(:contract) do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          router x
          exit
          contract c
           require x type string pattern "(unclosed"
          exit
        PRC
      )
      doc.contracts.first
    end

    it "reports :invalid_pattern when the regex fails to compile" do
      v = described_class.validate(contract, { "x" => "anything" })
      kinds = v.map(&:kind)
      expect(kinds).to include(:invalid_pattern)
    end
  end
end
