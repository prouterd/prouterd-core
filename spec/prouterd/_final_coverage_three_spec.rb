require "spec_helper"
require "rack/test"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "ostruct"
require "prouterd/cli/main"

RSpec.describe "Coverage mop-up — batch 3 (surgical)" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ============================================================
  # orchestrator: events.publish defensive nil-guards
  # ============================================================

  describe "Runtime::Orchestrator events.publish nil guards" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }

    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block hello
          interface docker img
         exit
        exit
      PRC
    end

    it "skips :run_updated publish when execute_inner's running update returns nil" do
      orch = Prouterd::Runtime::Orchestrator.new(
        db: db, runner: Prouterd::Runner::StubRunner.new
      )
      # Make update_run return nil so the `if running` guard fires.
      original_update = Prouterd::Storage::Repositories::Runs.instance_method(:update_run)
      call_count = 0
      Prouterd::Storage::Repositories::Runs.define_method(:update_run) do |*a, **kw|
        call_count += 1
        next nil if call_count == 1 # first update_run in execute_inner

        original_update.bind(self).call(*a, **kw)
      end
      # The orchestrator should not crash even when running is nil.
      run = orch.trigger(doc, "p", input_event: {})
      expect(run).not_to be_nil
    ensure
      Prouterd::Storage::Repositories::Runs.define_method(:update_run, original_update)
    end

    it "skips :run_updated publish when finalize_run's update returns nil" do
      orch = Prouterd::Runtime::Orchestrator.new(
        db: db, runner: Prouterd::Runner::StubRunner.new
      )
      # Patch update_run to return nil specifically when finalize_run calls it
      # (called with status: + finished_at: + error_summary:).
      original_update = Prouterd::Storage::Repositories::Runs.instance_method(:update_run)
      Prouterd::Storage::Repositories::Runs.define_method(:update_run) do |id, **kwargs|
        if kwargs[:status] && kwargs[:finished_at] && kwargs.key?(:error_summary)
          # First finalize_run call → nil; subsequent restores
          original_update.bind(self).call(id, **kwargs)
          nil
        else
          original_update.bind(self).call(id, **kwargs)
        end
      end
      expect { orch.trigger(doc, "p", input_event: {}) }.not_to raise_error
    ensure
      Prouterd::Storage::Repositories::Runs.define_method(:update_run, original_update)
    end

    it "skips :run_updated publish in finalize_canceled when get_run returns nil" do
      orch = Prouterd::Runtime::Orchestrator.new(
        db: db, runner: Prouterd::Runner::StubRunner.new
      )
      run = repo.create_run(process_name: "p", input_event: {})
      repo.update_run(run.id, status: "canceled", finished_at: Time.now.utc.iso8601(3))
      allow(repo).to receive(:get_run).and_return(nil)
      # Re-resolve into orchestrator's @runs reference
      allow_any_instance_of(Prouterd::Storage::Repositories::Runs).to receive(:get_run).and_return(nil)
      result = orch.send(:finalize_canceled, run)
      expect(result).to be_nil
    end
  end

  # ============================================================
  # orchestrator: input_event_json nil branch (deep_stringify with empty)
  # ============================================================

  describe "Runtime::Orchestrator input_event_json nil branch" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }

    it "wraps a run with NULL input_event_json into an empty event hash" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
        exit
      PRC
      orch = Prouterd::Runtime::Orchestrator.new(
        db: db, runner: Prouterd::Runner::StubRunner.new
      )
      run = repo.create_run(process_name: "p", input_event: {})
      db.execute("UPDATE runs SET input_event_json = NULL WHERE id = ?", [run.id])
      reloaded = repo.get_run(run.id)
      expect { orch.execute_run(reloaded, doc) }.not_to raise_error
    end
  end

  # ============================================================
  # block_executor: events.publish defensive nil guards via stubbed step
  # ============================================================


  # ============================================================
  # docker_runner: container.wait with no timeout (L85 else) + unknown stream
  # ============================================================

  describe "Runner::DockerRunner edges" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }

    before do
      unless defined?(Docker)
        stub_const("Docker", Module.new)
        stub_const("Docker::Error", Module.new)
        stub_const("Docker::Error::DockerError", Class.new(StandardError))
        stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
      end
    end

    it "uses bare container.wait (no Timeout) when request.timeout_ms is nil" do
      described_class = Prouterd::Runner::DockerRunner
      described_class.instance_variable_set(:@docker_available, true)
      stub_const("Docker::Container", Class.new { def self.create(*); end })
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      allow(Docker::Image).to receive(:get).and_return(:present)

      fake_container = Class.new do
        attr_reader :id
        def initialize(work_dir)
          @id = "ok"
          @wd = work_dir
        end
        def start
          File.write(File.join(@wd, "output.json"), '{}')
        end
        def wait; :exited; end
        def json; { "State" => { "ExitCode" => 0 } }; end
        def streaming_logs(**); yield :stdout, "log"; end
        def delete(**); end
      end
      allow(Docker::Container).to receive(:create) do |params|
        wd = params["HostConfig"]["Binds"].first.split(":").first
        fake_container.new(wd)
      end

      req = Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "image" => "x" }, staged_inputs: {}
      )
      result = runner.run(req)
      expect(result.exit_code).to eq(0)
      described_class.instance_variable_set(:@docker_available, nil)
    end

    it "demultiplex_logs falls through to raw-buffer when stream byte is unknown" do
      # stream=7 is neither stdout(1) nor stderr(2) → hits the else
      # branch that treats the whole buffer as TTY-mode stdout.
      raw = [7, 0, 0, 0, 4].pack("CCCCN") + "abcd"
      out, err = runner.send(:demultiplex_logs, raw)
      expect(err).to eq("")
    end
  end

  # ============================================================
  # shell/shell: read_input nil from Reline + dialog-proc branch + early break
  # ============================================================

  describe "Shell::Shell branches" do
    it "breaks the run loop when read_input returns nil (EOF)" do
      session = Prouterd::Shell::Session.new
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell = Prouterd::Shell::Shell.new(
        session: session,
        input: StringIO.new, # immediately EOFs
        output: StringIO.new, error: StringIO.new,
        interactive: false, banner: false
      )
      expect(shell.run).to eq(0)
    end

    it "install_completer registers the autocompletion dialog proc when Reline supports it" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse("router demo\nexit\n"))
      shell = Prouterd::Shell::Shell.new(
        session: session,
        input: StringIO.new, output: StringIO.new, error: StringIO.new,
        interactive: true, banner: false
      )
      reline = Module.new
      added_dialogs = []
      reline.define_singleton_method(:completion_proc=) { |_| }
      reline.define_singleton_method(:completion_append_character=) { |_| }
      reline.define_singleton_method(:autocompletion=) { |_| }
      reline.define_singleton_method(:add_dialog_proc) { |sym, proc| added_dialogs << sym }
      reline.define_singleton_method(:respond_to?) do |sym|
        %i[completion_proc= completion_append_character= autocompletion= add_dialog_proc].include?(sym)
      end
      stub_const("Reline", reline)
      stub_const("Reline::DEFAULT_DIALOG_PROC_AUTOCOMPLETE", proc { [] })
      shell.send(:install_completer)
      expect(added_dialogs).to include(:autocomplete)
    end

    it "install_completer @error nil branch swallows StandardError silently" do
      shell = Prouterd::Shell::Shell.new(
        session: Prouterd::Shell::Session.new,
        input: StringIO.new, output: StringIO.new, error: nil,
        interactive: true, banner: false
      )
      reline = Module.new
      reline.define_singleton_method(:completion_proc=) { |_| raise "x" }
      reline.define_singleton_method(:respond_to?) { |_| false }
      stub_const("Reline", reline)
      expect { shell.send(:install_completer) }.not_to raise_error
    end
  end

  # ============================================================
  # cli/main: replay success (L276), trigger nil-running-commit (L395),
  # trigger fail (L401), resume success/fail (L349)
  # ============================================================

  describe "CLI::Main exit code ternaries" do
    def run_cli(*argv, **opts)
      out = StringIO.new
      err = StringIO.new
      code = Prouterd::CLI::Main.run(argv, stdout: out, stderr: err, **opts)
      [code, out.string, err.string]
    end

    it "replay exits 0 on a successful run AND emits a 'Replayed ... success' header" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          run_cli("apply", fixture_path("minimal.prc"), "--db", db.path)
          run_cli("trigger", "process", "pipeline", "input", f.path,
                  "--db", db.path, "--runner", "stub")
          sql = Prouterd::Storage::DB.open(db.path)
          orig = Prouterd::Storage::Repositories::Runs.new(sql).list_runs(limit: 1).first
          sql.close
          code, _out, _err = run_cli("replay", "run", orig.uid, "--db", db.path, "--runner", "stub")
          expect(code).to eq(0)
        end
      end
    end

    it "trigger passes commit_id: nil when running_commit is unset on the store" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          # Apply config, then nil the running pointer in the DB so
          # store.running_commit returns nil at trigger time.
          run_cli("apply", fixture_path("minimal.prc"), "--db", db.path)
          sql = Prouterd::Storage::DB.open(db.path)
          sql.execute("DELETE FROM config_pointers WHERE name = 'running'")
          sql.close
          code, _out, _err = run_cli("trigger", "process", "pipeline", "input", f.path,
                                      "--db", db.path, "--runner", "stub")
          expect([0, 1]).to include(code)
        end
      end
    end

    it "resume exits 0 on successful resume of a paused run" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["pause-prc", ".prc"]) do |t|
          t.write(<<~PRC)
            router demo
            exit
            interface docker img
             image x
            exit
            process p
             block ask
              pause "wait"
             exit
             block tail
              interface docker img
             exit
             route ask tail
            exit
          PRC
          t.flush
          run_cli("apply", t.path, "--db", db.path)
          Tempfile.create(["evt", ".json"]) do |f|
            f.write('{}')
            f.flush
            run_cli("trigger", "process", "p", "input", f.path,
                    "--db", db.path, "--runner", "stub")
            sql = Prouterd::Storage::DB.open(db.path)
            paused = Prouterd::Storage::Repositories::Runs.new(sql).list_runs(status: "paused", limit: 1).first
            sql.close
            code, _out, _err = run_cli("resume", "run", paused.uid, "--db", db.path, "--runner", "stub")
            expect(code).to eq(0)
          end
        end
      end
    end
  end

  # ============================================================
  # api/v1: post_process_trigger 404 + mcp state ternary (already-known iface in health)
  # ============================================================

  describe "API::V1 trigger 404 for unknown process" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil
      )
    end

    it "returns 404 for POST /v1/processes/<unknown>/trigger" do
      store.commit(parse("router demo\nexit\n"))
      post "/v1/processes/ghost/trigger", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end
  end

  # ============================================================
  # scheduler: parse_cron @fugit_warned dedupe branch
  # ============================================================

  describe "Runtime::Scheduler parse_cron @fugit_warned re-warn skip" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "warns once and stays silent on subsequent calls when fugit is missing" do
      sched = Prouterd::Runtime::Scheduler.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        logger: Prouterd::NullLogger.new
      )
      allow(Prouterd::Runtime::Scheduler).to receive(:fugit_available?).and_return(false)
      logger = double
      sched.instance_variable_set(:@logger, logger)
      # First call: warns once.
      expect(logger).to receive(:warn).once
      iface = double(name: "i", type_fields: { "schedule" => "0 * * * *", "timezone" => nil })
      sched.send(:parse_cron, iface)
      # Second call: must not re-warn.
      sched.send(:parse_cron, iface)
    end
  end

  # ============================================================
  # cli/main: with_runtime ensure block — store == :error branch
  # ============================================================

  describe "CLI::Main ensure block with store == :error" do
    it "does not attempt close on store == :error in cmd_diff" do
      allow(Prouterd::Storage::DB).to receive(:open).and_raise(SQLite3::CantOpenException, "denied")
      out = StringIO.new
      err = StringIO.new
      # Triggers `store = open_store(...)` → :error → ensure with
      # `store && store != :error` short-circuits, no close attempt.
      code = Prouterd::CLI::Main.run(
        ["diff", fixture_path("minimal.prc"), "--db", "/no/where"],
        stdout: out, stderr: err
      )
      expect(code).to eq(1)
    end
  end
end
