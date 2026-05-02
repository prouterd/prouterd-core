require "spec_helper"

RSpec.describe Prouterd::Config::Lexer do
  def tokenize(src)
    described_class.tokenize(src)
  end

  it "produces no lines for empty input" do
    expect(tokenize("")).to be_empty
  end

  it "skips blank lines and comment-only lines" do
    src = <<~SRC
      ! comment
      # hash comment

         ! indented comment
    SRC
    expect(tokenize(src)).to be_empty
  end

  it "tokenizes a simple line" do
    lines = tokenize("router demo")
    expect(lines.length).to eq(1)
    expect(lines.first.number).to eq(1)
    expect(lines.first.tokens.map(&:value)).to eq(["router", "demo"])
    expect(lines.first.tokens.map(&:type)).to eq(%i[word word])
  end

  it "tracks line numbers across multiple lines" do
    src = "router demo\nversion 1\nexit"
    lines = tokenize(src)
    expect(lines.map(&:number)).to eq([1, 2, 3])
  end

  it "preserves line numbers when blank lines are skipped" do
    src = "router demo\n\n\nversion 1\n"
    lines = tokenize(src)
    expect(lines.map(&:number)).to eq([1, 4])
  end

  it "tokenizes quoted strings as a single token" do
    lines = tokenize('description "Lead enrichment and sales"')
    tokens = lines.first.tokens
    expect(tokens.length).to eq(2)
    expect(tokens[1].type).to eq(:string)
    expect(tokens[1].value).to eq("Lead enrichment and sales")
  end

  it "handles escaped quotes inside strings" do
    lines = tokenize('description "say \"hi\" twice"')
    expect(lines.first.tokens[1].value).to eq('say "hi" twice')
  end

  it "raises LexError on unterminated string" do
    expect { tokenize('description "oops') }.to raise_error(Prouterd::Config::LexError, /unterminated string/)
  end

  it "treats # and ! as comments only at token boundary" do
    lines = tokenize("image foo!bar")
    tokens = lines.first.tokens
    expect(tokens.map(&:value)).to eq(["image", "foo!bar"])
  end

  it "treats ! as inline comment after whitespace" do
    lines = tokenize("router demo ! the only router")
    expect(lines.first.tokens.map(&:value)).to eq(["router", "demo"])
  end

  it "tracks columns of each token" do
    lines = tokenize("  router demo")
    tokens = lines.first.tokens
    expect(tokens[0].column).to eq(3)
    expect(tokens[1].column).to eq(10)
  end
end
