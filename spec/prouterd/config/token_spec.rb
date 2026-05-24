require "spec_helper"

RSpec.describe Prouterd::Config::Token do
  it "word? is true for :word tokens" do
    expect(described_class.new(:word, "hello", 1, 1).word?).to be(true)
    expect(described_class.new(:string, "hello", 1, 1).word?).to be(false)
  end

  it "string? is true for :string tokens" do
    expect(described_class.new(:string, "x", 1, 1).string?).to be(true)
    expect(described_class.new(:word, "x", 1, 1).string?).to be(false)
  end

  it "to_s renders a word token as the raw value" do
    expect(described_class.new(:word, "hello", 1, 1).to_s).to eq("hello")
  end

  it "to_s renders a string token as its inspected form" do
    expect(described_class.new(:string, "hello world", 1, 1).to_s).to eq('"hello world"')
  end
end

RSpec.describe Prouterd::Config::Line do
  let(:t1) { Prouterd::Config::Token.new(:word, "head", 1, 1) }
  let(:t2) { Prouterd::Config::Token.new(:word, "tail", 1, 6) }

  it "head returns the first token" do
    expect(described_class.new(1, [t1, t2]).head).to eq(t1)
  end

  it "rest returns the tokens after head" do
    expect(described_class.new(1, [t1, t2]).rest).to eq([t2])
  end

  it "rest returns [] when there's no tail" do
    expect(described_class.new(1, [t1]).rest).to eq([])
  end

  it "rest returns [] when tokens is empty (head-less line)" do
    expect(described_class.new(1, []).rest).to eq([])
  end
end
