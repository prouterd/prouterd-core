require "spec_helper"
require "stringio"
require "tempfile"
require "prouterd/daemon"

RSpec.describe Prouterd::Daemon::Main do
  def drive(argv)
    stdin = StringIO.new
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.run(argv, stdin: stdin, stdout: stdout, stderr: stderr)
    [code, stdout.string, stderr.string]
  end

  describe "argv parsing — short flags" do
    %w[-v -h].each do |flag|
      it "responds to #{flag}" do
        code, out, _err = drive([flag])
        expect(code).to eq(0)
        expect(out).not_to be_empty
      end
    end

    it "rejects --port with no value" do
      code, _out, err = drive(["--port"])
      expect(code).to eq(2)
      expect(err).to include("--port requires a value")
    end

    it "rejects --db with no value" do
      code, _out, err = drive(["--db"])
      expect(code).to eq(2)
      expect(err).to include("--db requires a value")
    end

    it "rejects --runner with no value" do
      code, _out, err = drive(["--runner"])
      expect(code).to eq(2)
      expect(err).to include("--runner requires a value")
    end

    it "rejects --workers with no value" do
      code, _out, err = drive(["--workers"])
      expect(code).to eq(2)
      expect(err).to include("--workers requires a value")
    end

    it "rejects --console-dir with no value" do
      code, _out, err = drive(["--console-dir"])
      expect(code).to eq(2)
      expect(err).to include("--console-dir requires a value")
    end

    it "accepts -b / -p / --workers / --runner together" do
      Tempfile.create(["prouterd-cfg", ".sqlite3"]) do |t|
        t.close
        # Boot far enough to hit the storage probe + Server.run; both are
        # heavy, so stub everything past parse_args.
        instance = described_class.new(
          ["-b", "127.0.0.1", "-p", "0", "--db", t.path, "--workers", "1",
           "--runner", "stub"],
          StringIO.new, StringIO.new, StringIO.new
        )
        # Just exercise parse_args end-to-end.
        opts = instance.send(:parse_args)
        expect(opts).to include(bind: "127.0.0.1", port: 0, workers: 1, runner_kind: "stub")
        expect(opts[:db_path]).to eq(t.path)
      end
    end
  end

  describe "console_dir validation" do
    it "exits 2 when --console-dir points at a non-directory" do
      Tempfile.create(["prouterd", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["prouterd-c", "-conf"]) do |regular_file|
          # path is a regular file, not a directory
          stubbed = described_class.new(
            ["--db", db.path, "--console-dir", regular_file.path],
            StringIO.new, StringIO.new, (err = StringIO.new)
          )
          # We must mock Server.run / runtime so we get to the directory check
          allow(Prouterd::API::Server).to receive(:run)
          allow(Prouterd::Daemon::Lock).to receive(:acquire).and_return(IO.sysopen("/dev/null"))
          allow_any_instance_of(Prouterd::Runtime::WorkerPool).to receive(:run)
          allow_any_instance_of(Prouterd::Runtime::WorkerPool).to receive(:stop)
          allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:run)
          allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:stop)
          allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:start_or_reconcile)
          allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:stop)
          allow_any_instance_of(Prouterd::API::App).to receive(:start_storage_probe)
          allow_any_instance_of(Prouterd::API::App).to receive(:stop_storage_probe)
          code = stubbed.run
          expect(code).to eq(2)
          expect(err.string).to include("not a directory")
        end
      end
    end
  end

  describe "lock failure" do
    it "exits 3 when the DB lock can't be acquired" do
      Tempfile.create(["prouterd", ".sqlite3"]) do |db|
        db.close
        allow(Prouterd::Daemon::Lock).to receive(:acquire).and_raise(
          Prouterd::Daemon::LockError, "another daemon is running"
        )
        code, _out, err = drive(["--db", db.path])
        expect(code).to eq(3)
        expect(err).to include("another daemon")
      end
    end
  end

  describe "open_store error path" do
    it "exits 1 when open_store returns :error" do
      Tempfile.create(["prouterd", ".sqlite3"]) do |db|
        db.close
        instance = described_class.new(
          ["--db", db.path],
          StringIO.new, StringIO.new, (err = StringIO.new)
        )
        allow(instance).to receive(:open_store).and_return(:error)
        expect(instance.run).to eq(1)
      end
    end
  end
end
