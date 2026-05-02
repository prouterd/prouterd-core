require "spec_helper"
require "stringio"
require "prouterd/daemon"

RSpec.describe Prouterd::Daemon::Main do
  def drive(argv)
    stdin = StringIO.new
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.run(argv, stdin: stdin, stdout: stdout, stderr: stderr)
    [code, stdout.string, stderr.string]
  end

  describe "argv parsing — short-circuit options" do
    it "--version prints the version and returns 0" do
      code, out, err = drive(["--version"])
      expect(code).to eq(0)
      expect(out).to match(/\Aprouterd \d+\.\d+\.\d+\n\z/)
      expect(err).to be_empty
    end

    it "--help prints usage and returns 0" do
      code, out, err = drive(["--help"])
      expect(code).to eq(0)
      expect(out).to include("Usage: prouterd")
      expect(out).to include("--bind")
      expect(out).to include("--workers")
      expect(out).to include("PROUTERD_ADMIN_TOKEN")
      expect(err).to be_empty
    end
  end

  describe "argv parsing — validation" do
    it "rejects --port with non-integer value" do
      code, _out, err = drive(["--port", "abc"])
      expect(code).to eq(2)
      expect(err).to include("--port must be an integer")
    end

    it "rejects --workers with non-integer value" do
      code, _out, err = drive(["--workers", "x"])
      expect(code).to eq(2)
      expect(err).to include("--workers must be an integer")
    end

    it "rejects unknown flags" do
      code, _out, err = drive(["--unknown-flag"])
      expect(code).to eq(2)
      expect(err).to include("unknown option '--unknown-flag'")
    end

    it "rejects --bind with no value" do
      code, _out, err = drive(["--bind"])
      expect(code).to eq(2)
      expect(err).to include("--bind requires a value")
    end
  end

  describe "store policy" do
    it "refuses --no-db: the daemon requires persistent state" do
      code, _out, err = drive(["--no-db"])
      expect(code).to eq(2)
      expect(err).to include("requires --db")
      expect(err).to include("persistent state")
    end
  end
end
