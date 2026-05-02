require "spec_helper"

RSpec.describe Prouterd::Runtime::Redactor do
  it "is empty when no secrets are passed" do
    expect(described_class.new([]).empty?).to be(true)
    expect(described_class.new(nil).empty?).to be(true)
  end

  it "redacts a secret value to ********" do
    r = described_class.new(["topsecret"])
    expect(r.redact("leaked: topsecret here")).to eq("leaked: ******** here")
  end

  it "redacts multiple distinct secrets" do
    r = described_class.new(["alpha", "beta"])
    expect(r.redact("alpha and beta")).to eq("******** and ********")
  end

  it "handles overlapping secrets by length-first ordering" do
    r = described_class.new(["abc", "abcdef"])
    expect(r.redact("abcdef abc")).to eq("******** ********")
  end

  it "ignores nil and empty values" do
    r = described_class.new([nil, "", "real"])
    expect(r.redact("real value")).to eq("******** value")
  end

  it "passes through nil and empty input unchanged" do
    r = described_class.new(["x"])
    expect(r.redact(nil)).to be_nil
    expect(r.redact("")).to eq("")
  end

  it "from_document collects every declared secret's resolved value" do
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      secret A_TOKEN
       source env A_TOKEN
      exit
      secret B_TOKEN
       source env B_TOKEN
      exit
    PRC
    ENV["A_TOKEN"] = "alpha-real"
    ENV["B_TOKEN"] = "beta-real"
    begin
      r = described_class.from_document(doc, Prouterd::Runtime::EnvSecretResolver.new)
      expect(r.redact("alpha-real and beta-real")).to eq("******** and ********")
    ensure
      ENV.delete("A_TOKEN")
      ENV.delete("B_TOKEN")
    end
  end
end
