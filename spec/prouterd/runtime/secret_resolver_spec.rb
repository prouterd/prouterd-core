require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Runtime::EnvSecretResolver do
  let(:resolver) { described_class.new }
  Secret = Struct.new(:source_type, :source_value, keyword_init: true)

  describe "source env" do
    it "reads the named env var" do
      ENV["ORK_TEST_TOKEN"] = "abc"
      s = Secret.new(source_type: "env", source_value: "ORK_TEST_TOKEN")
      expect(resolver.resolve(s)).to eq("abc")
    ensure
      ENV.delete("ORK_TEST_TOKEN")
    end

    it "returns nil for an unset env var" do
      s = Secret.new(source_type: "env", source_value: "ORK_DEFINITELY_UNSET_#{Time.now.to_i}")
      expect(resolver.resolve(s)).to be_nil
    end
  end

  describe "source file" do
    it "reads file contents and trims a trailing newline (Docker secrets convention)" do
      Tempfile.open("ork_secret") do |f|
        f.write("supersecret\n")
        f.flush
        s = Secret.new(source_type: "file", source_value: f.path)
        expect(resolver.resolve(s)).to eq("supersecret")
      end
    end

    it "returns nil when the file is missing" do
      s = Secret.new(source_type: "file", source_value: "/nope/does/not/exist/#{Time.now.to_i}")
      expect(resolver.resolve(s)).to be_nil
    end
  end

  describe "unsupported source" do
    it "raises TriggerError" do
      s = Secret.new(source_type: "vault", source_value: "kv/foo")
      expect { resolver.resolve(s) }.to raise_error(Prouterd::Runtime::TriggerError, /unsupported secret source/)
    end
  end
end

RSpec.describe "secret DSL parser accepts source file" do
  it "parses `source file <path>`" do
    src = <<~PRC
      router x
      exit
      secret API_TOKEN
       source file /run/secrets/api_token
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
    s = doc.secrets.first
    expect(s.source_type).to eq("file")
    expect(s.source_value).to eq("/run/secrets/api_token")
  end

  it "round-trips through the renderer" do
    src = <<~PRC
      router x
      exit
      secret API_TOKEN
       source file /run/secrets/api_token
      exit
    PRC
    doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
    rendered = Prouterd::Config::Renderer.render(doc)
    expect(rendered).to include("source file /run/secrets/api_token")
    reparsed = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(rendered))
    expect(reparsed.secrets.first.source_type).to eq("file")
  end

  it "rejects unsupported sources with a clear error" do
    src = <<~PRC
      router x
      exit
      secret X
       source vault kv/foo
      exit
    PRC
    expect do
      Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
    end.to raise_error(Prouterd::Config::ParseError, /unsupported secret source 'vault'/)
  end
end
