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

  it "exits 1 for invalid config (missing interface directive)" do
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
      expect(out).to include("missing `interface")
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

  describe "apply" do
    def run_apply(*argv)
      out = StringIO.new
      err = StringIO.new
      stdin = StringIO.new
      code = described_class.run(["apply", *argv], stdin: stdin, stdout: out, stderr: err)
      [code, out.string, err.string]
    end

    it "validates and persists a commit when --db is provided" do
      Tempfile.create(["prouterd-apply-", ".sqlite3"]) do |tmp|
        tmp.close
        code, out, _ = run_apply(fixture_path("minimal.prc"), "--db", tmp.path)
        expect(code).to eq(0)
        expect(out).to match(/Applied .* as commit 1/)

        # Second apply creates commit 2.
        code, out, _ = run_apply(fixture_path("sales_ops.prc"), "--db", tmp.path)
        expect(code).to eq(0)
        expect(out).to match(/Applied .* as commit 2/)
      end
    end

    it "without DB warns that nothing was persisted" do
      code, out, _ = run_apply(fixture_path("minimal.prc"), "--no-db")
      expect(code).to eq(0)
      expect(out).to include("not persisted")
    end

    it "exits 1 on validation failure (does not persist)" do
      Tempfile.create(["prouterd-apply-bad-", ".sqlite3"]) do |sqltmp|
        sqltmp.close
        Tempfile.create(["bad", ".prc"]) do |bad|
          bad.write("router x\nexit\nprocess p\nexit\n")
          bad.flush
          code, _, err = run_apply(bad.path, "--db", sqltmp.path)
          expect(code).to eq(1)
          expect(err).to include("has no blocks")
        end
        # Verify no commits landed.
        db = Prouterd::Storage::DB.open(sqltmp.path)
        expect(db.execute("SELECT COUNT(*) FROM config_commits").first.first).to eq(0)
        db.close
      end
    end
  end

  describe "shell" do
    def run_shell(stdin_text, *argv)
      out = StringIO.new
      err = StringIO.new
      stdin = StringIO.new(stdin_text)
      code = described_class.run(["shell", *argv], stdin: stdin, stdout: out, stderr: err)
      [code, out.string, err.string]
    end

    it "runs interactive shell to completion via piped stdin" do
      code, out, _ = run_shell("show version\nexit\n", "--no-db")
      expect(code).to eq(0)
      expect(out).to include("prouter #{Prouterd::VERSION}")
    end

    it "loads --config and shows it from privileged mode" do
      code, out, _ = run_shell(
        "enable\nshow running-config\nexit\n",
        "--no-db", "--config", fixture_path("minimal.prc")
      )
      expect(code).to eq(0)
      expect(out).to include("router demo")
    end
  end
end
