require "spec_helper"

RSpec.describe Prouterd::Shell::CommandLine do
  describe ".tokenize" do
    it "returns nil for an entirely blank string" do
      expect(described_class.tokenize("")).to be_nil
      expect(described_class.tokenize("   ")).to be_nil
    end

    it "returns nil for a comment-only line" do
      expect(described_class.tokenize("! a comment")).to be_nil
    end

    it "returns an array of Tokens for a normal command line" do
      tokens = described_class.tokenize("show running-config")
      expect(tokens).to be_a(Array)
      expect(tokens.map(&:value)).to eq(["show", "running-config"])
    end

    it "only uses the first line when given multi-line input" do
      tokens = described_class.tokenize("show clock\nignored second line")
      expect(tokens.map(&:value)).to eq(["show", "clock"])
    end
  end

  describe ".words" do
    it "returns nil for blank input" do
      expect(described_class.words("")).to be_nil
      expect(described_class.words("   ")).to be_nil
    end

    it "returns string array for normal input" do
      expect(described_class.words("enable")).to eq(["enable"])
      expect(described_class.words("show running-config")).to eq(["show", "running-config"])
    end
  end
end
