require "spec_helper"
require "prouterd/cli/main"
require "stringio"
require "tempfile"

RSpec.describe Prouterd::CLI::Main do
  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(argv, stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  it "prints version" do
    code, out, _err = run("version")
    expect(code).to eq(0)
    expect(out).to include("prouter #{Prouterd::VERSION}")
  end

  it "prints help when no args given" do
    code, out, _err = run
    expect(code).to eq(0)
    expect(out).to include("Usage: prouter")
  end

  it "exits 0 for valid config" do
    code, out, _err = run("check", fixture_path("sales_ops.prc"))
    expect(code).to eq(0)
    expect(out).to include("Config valid.")
    expect(out).to include("Router:")
    expect(out).to include("sales_ops")
  end

  it "exits 1 for invalid config (missing image)" do
    Tempfile.create(["bad", ".prc"]) do |tmp|
      tmp.write(<<~PRC)
        router x
        exit
        process p
         block a
         exit
        exit
      PRC
      tmp.flush
      code, out, _err = run("check", tmp.path)
      expect(code).to eq(1)
      expect(out).to include("Config invalid.")
      expect(out).to include("missing 'image'")
    end
  end

  it "exits 1 with parse error pointing to line number" do
    Tempfile.create(["bad", ".prc"]) do |tmp|
      tmp.write(<<~PRC)
        router x
         color red
        exit
      PRC
      tmp.flush
      code, _out, err = run("check", tmp.path)
      expect(code).to eq(1)
      expect(err).to include("line 2:")
      expect(err).to include("unknown directive 'color'")
    end
  end

  it "exits 2 if file is missing" do
    code, _out, err = run("check", "/nonexistent/file.prc")
    expect(code).to eq(2)
    expect(err).to include("no such file")
  end

  it "render command emits canonical config" do
    code, out, _err = run("render", fixture_path("minimal.prc"))
    expect(code).to eq(0)
    expect(out).to include("router demo")
    expect(out).to include("block hello")
  end

  it "rejects unknown command with exit code 2" do
    code, _out, err = run("frobnicate")
    expect(code).to eq(2)
    expect(err).to include("unknown command 'frobnicate'")
  end
end
