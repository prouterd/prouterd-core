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

  # Drives `run` end-to-end with the heavy components (Puma, worker
  # threads, MCP subprocesses) injected as no-ops so the daemon's
  # boot-and-shutdown sequence executes inline. Hits the
  # `start_storage_probe` / `Server.run` / `ensure` cleanup chain that
  # otherwise needs a real `prouterd` process to cover.
  describe "happy-path boot + ordered shutdown" do
    def stub_all_subsystems!
      allow(Prouterd::Daemon::Lock).to receive(:acquire).and_return(IO.sysopen("/dev/null"))
      allow_any_instance_of(Prouterd::Runtime::WorkerPool).to receive(:run)
      allow_any_instance_of(Prouterd::Runtime::WorkerPool).to receive(:stop)
      allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:run)
      allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:stop)
      allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:start_or_reconcile)
      allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:stop)
      allow_any_instance_of(Prouterd::API::App).to receive(:start_storage_probe)
      allow_any_instance_of(Prouterd::API::App).to receive(:stop_storage_probe)
    end

    it "returns 0 after Server.run unblocks and runs the ensure-block cleanup in order" do
      Tempfile.create(["prouterd-happy-", ".sqlite3"]) do |db|
        db.close
        stub_all_subsystems!

        shutdown_order = []
        allow_any_instance_of(Prouterd::API::App).to receive(:stop_storage_probe) { shutdown_order << :probe }
        allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:stop) { shutdown_order << :scheduler }
        allow_any_instance_of(Prouterd::Runtime::WorkerPool).to receive(:stop) { shutdown_order << :workers }
        allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:stop)    { shutdown_order << :mcp }

        captured_server_args = nil
        allow(Prouterd::API::Server).to receive(:run) do |**kwargs|
          captured_server_args = kwargs
          # simulate Server.run returning when the operator hits SIGTERM
          nil
        end

        out = StringIO.new
        code = described_class.run(["--db", db.path, "--bind", "127.0.0.1", "--port", "0"],
                                    stdin: StringIO.new, stdout: out, stderr: StringIO.new)
        expect(code).to eq(0)
        expect(captured_server_args[:bind]).to eq("127.0.0.1")
        expect(captured_server_args[:port]).to eq(0)
        # Shutdown sequence: probe → scheduler → workers → mcp. This
        # order matters because the storage probe writes to the same
        # DB the worker threads do; stopping it first means no probe
        # row collides with a worker-driven mid-shutdown write.
        expect(shutdown_order).to eq([:probe, :scheduler, :workers, :mcp])
      end
    end

    it "exits 2 when --console-dir is a regular file and never reaches Server.run" do
      Tempfile.create(["prouterd-cd-", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["prouterd-cd-conf-"]) do |reg_file|
          stub_all_subsystems!
          expect(Prouterd::API::Server).not_to receive(:run)

          err = StringIO.new
          code = described_class.run(
            ["--db", db.path, "--console-dir", reg_file.path],
            stdin: StringIO.new, stdout: StringIO.new, stderr: err
          )
          expect(code).to eq(2)
          expect(err.string).to include("not a directory")
        end
      end
    end

    it "accepts a valid --console-dir and forwards it to App via expand_path" do
      Tempfile.create(["prouterd-cd-", ".sqlite3"]) do |db|
        db.close
        Dir.mktmpdir do |dir|
          stub_all_subsystems!
          captured_console_dir = nil
          allow(Prouterd::API::App).to receive(:new).and_wrap_original do |orig, **kwargs|
            captured_console_dir = kwargs[:console_dir]
            orig.call(**kwargs)
          end
          allow(Prouterd::API::Server).to receive(:run)

          described_class.run(["--db", db.path, "--console-dir", dir],
                              stdin: StringIO.new, stdout: StringIO.new, stderr: StringIO.new)
          expect(captured_console_dir).to eq(File.expand_path(dir))
        end
      end
    end

    it "swallows StandardError from the initial mcp pool reconcile and continues to boot" do
      Tempfile.create(["prouterd-mcp-", ".sqlite3"]) do |db|
        db.close
        stub_all_subsystems!
        allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:start_or_reconcile)
          .and_raise(StandardError, "mcp server unreachable")
        allow(Prouterd::API::Server).to receive(:run)

        out = StringIO.new
        code = described_class.run(["--db", db.path],
                                    stdin: StringIO.new, stdout: out, stderr: StringIO.new)
        expect(code).to eq(0)
        # The warning is structured-logged to stdout via Logger.build.
        expect(out.string).to include("mcp pool initial reconcile failed")
        expect(out.string).to include("mcp server unreachable")
      end
    end

    it "swallows StandardError from a config_changed-driven mcp reconcile" do
      Tempfile.create(["prouterd-mcp2-", ".sqlite3"]) do |db|
        db.close
        stub_all_subsystems!

        # Capture the events subscription so we can fire it ourselves
        # after the daemon's run() returns — by which point @logger /
        # mcp_pool are already initialised and live for the block.
        fire_event = nil
        allow(Prouterd::Events).to receive(:subscribe).and_call_original
        allow(Prouterd::Events).to receive(:subscribe).with(:config_changed) do |&blk|
          fire_event = blk
          Prouterd::Events.default.subscribe(:config_changed, &blk)
        end
        allow(Prouterd::API::Server).to receive(:run) do
          # Now fire the event with the mcp pool stub raising
          allow_any_instance_of(Prouterd::Iface::Mcp::Pool).to receive(:start_or_reconcile)
            .and_raise(StandardError, "mid-run mcp blew up")
          fire_event&.call(:config_changed, {})
        end

        out = StringIO.new
        code = described_class.run(["--db", db.path],
                                    stdin: StringIO.new, stdout: out, stderr: StringIO.new)
        expect(code).to eq(0)
        expect(out.string).to include("mcp pool reconcile on config_changed failed")
      end
    end
  end
end
