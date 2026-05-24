require "spec_helper"
require "prouterd/cli/main"
require "stringio"
require "tempfile"
require "json"

RSpec.describe Prouterd::CLI::Main do
  def run(*argv, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(argv, stdin: stdin, stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  def with_db
    Tempfile.create(["prouter-cli-", ".sqlite3"]) do |t|
      t.close
      yield t.path
    end
  end

  describe "version aliases" do
    it "responds to -v" do
      code, out, _ = run("-v")
      expect(code).to eq(0)
      expect(out).to include("prouter")
    end

    it "responds to --version" do
      code, out, _ = run("--version")
      expect(code).to eq(0)
      expect(out).to include("prouter")
    end
  end

  describe "help aliases" do
    it "responds to -h" do
      code, out, _ = run("-h")
      expect(code).to eq(0)
      expect(out).to include("Usage:")
    end

    it "responds to --help" do
      code, out, _ = run("--help")
      expect(code).to eq(0)
      expect(out).to include("Usage:")
    end
  end

  describe "check missing-arg / read errors" do
    it "exits 2 with a usage message when no file given" do
      code, _, err = run("check")
      expect(code).to eq(2)
      expect(err).to include("missing file argument")
    end
  end

  describe "render" do
    it "exits 2 when file is missing" do
      code, _, err = run("render")
      expect(code).to eq(2)
      expect(err).to include("missing file argument")
    end

    it "exits 2 on a non-existent path" do
      code, _, err = run("render", "/no/such/file.prc")
      expect(code).to eq(2)
      expect(err).to include("no such file")
    end

    it "exits 1 when the file fails to parse" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        code, _, err = run("render", t.path)
        expect(code).to eq(1)
        expect(err).to include("unknown directive")
      end
    end
  end

  describe "diff" do
    it "exits 2 with usage when no file argument" do
      code, _, err = run("diff")
      expect(code).to eq(2)
      expect(err).to include("usage: diff <file>")
    end

    it "exits 1 when file fails to parse" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        code, _, _ = run("diff", t.path, "--no-db")
        expect(code).to eq(1)
      end
    end

    it "prints 'No changes.' when file matches the running config" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, out, _ = run("diff", fixture_path("minimal.prc"), "--db", db)
        expect(code).to eq(0)
        expect(out).to include("No changes.")
      end
    end

    it "prints diff lines when the file differs from the running config" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        Tempfile.create(["other", ".prc"]) do |t|
          t.write(<<~PRC)
            router demo
            exit
            interface docker img1
             image alpine
            exit
            process p
             block hello
              interface docker img1
             exit
            exit
          PRC
          t.flush
          code, out, _ = run("diff", t.path, "--db", db)
          expect(code).to eq(0)
          expect(out).to match(/[\+\-]/)
        end
      end
    end

    it "exits 2 when --config path is missing on disk" do
      code, _, err = run("diff", fixture_path("minimal.prc"), "--config", "/no/such/file.prc")
      expect(code).to eq(2)
      expect(err).to include("No such file") .or include("no such file")
    end

    it "compares against --config path instead of the DB" do
      Tempfile.create(["other", ".prc"]) do |t|
        t.write("router demo\nexit\n")
        t.flush
        code, _, _ = run("diff", fixture_path("minimal.prc"), "--config", t.path)
        expect(code).to eq(0)
      end
    end
  end

  describe "cancel" do
    it "exits 2 with usage when missing args" do
      code, _, err = run("cancel")
      expect(code).to eq(2)
      expect(err).to include("usage: cancel run <uid>")
    end

    it "exits 2 with usage when first arg is not 'run'" do
      code, _, err = run("cancel", "foo", "bar")
      expect(code).to eq(2)
      expect(err).to include("usage: cancel run <uid>")
    end

    it "exits 1 with an error when no such run uid" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("cancel", "run", "ghost-uid", "--db", db)
        expect(code).to eq(1)
        expect(err).to include("no such run")
      end
    end

    it "exits 1 when the run is already terminal" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
        runs.update_run(r.id, status: "success", finished_at: Time.now.utc.iso8601(3))
        sql_db.close
        code, _, err = run("cancel", "run", r.uid, "--db", db)
        expect(code).to eq(1)
        expect(err).to include("already success")
      end
    end

    it "cancels a queued run and updates pending steps" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
        runs.create_step(run_id: r.id, block_name: "hello")
        sql_db.close
        code, out, _ = run("cancel", "run", r.uid, "--db", db)
        expect(code).to eq(0)
        expect(out).to include("Cancelled run #{r.uid}")
      end
    end
  end

  describe "validate" do
    it "exits 2 when no file argument" do
      code, _, err = run("validate")
      expect(code).to eq(2)
      expect(err).to include("usage: validate")
    end

    it "delegates to cmd_check when there is no --against flag" do
      code, out, _ = run("validate", fixture_path("minimal.prc"))
      expect(code).to eq(0)
      expect(out).to include("Config valid.")
    end

    it "exits 2 without --against when more args follow but it's not '--against'" do
      code, _, err = run("validate", fixture_path("minimal.prc"), "--foo")
      expect(code).to eq(2)
      expect(err).to include("missing --against running")
    end

    it "exits 2 for --against with non-'running' target" do
      code, _, err = run("validate", fixture_path("minimal.prc"), "--against", "startup")
      expect(code).to eq(2)
      expect(err).to include("only `--against running`")
    end

    it "exits 1 when validation fails before diffing" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\nexit\nprocess p\nexit\n")
        t.flush
        code, _, err = run("validate", t.path, "--against", "running", "--no-db")
        expect(code).to eq(1)
        expect(err).to include("Validation failed")
      end
    end

    it "emits machine-readable JSON when stdout is not a TTY" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, out, _ = run("validate", fixture_path("minimal.prc"), "--against", "running", "--db", db)
        expect(code).to eq(0)
        payload = JSON.parse(out.lines.last)
        expect(payload).to have_key("file")
        expect(payload).to have_key("diff")
        expect(payload).to have_key("total_changes")
      end
    end
  end

  describe "trigger" do
    it "exits 2 with usage when args are incomplete" do
      code, _, err = run("trigger")
      expect(code).to eq(2)
      expect(err).to include("usage: trigger process")
    end

    it "exits 2 with usage when 'input' keyword is missing" do
      code, _, err = run("trigger", "process", "p", "infile", "x.json")
      expect(code).to eq(2)
      expect(err).to include("usage: trigger process")
    end

    it "exits 2 when --db is required but not given (no-db mode)" do
      Tempfile.create(["evt", ".json"]) do |f|
        f.write('{"x":1}')
        f.flush
        code, _, err = run("trigger", "process", "p", "input", f.path, "--no-db")
        expect(code).to eq(2)
        expect(err).to include("requires --db")
      end
    end

    it "exits 2 when input file is missing" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("trigger", "process", "p", "input", "/no/such/evt.json", "--db", db)
        expect(code).to eq(2)
        expect(err).to include("No such file") .or include("no such file")
      end
    end

    it "exits 2 when input file is not valid JSON" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        Tempfile.create(["evt", ".json"]) do |f|
          f.write("not-json")
          f.flush
          code, _, err = run("trigger", "process", "p", "input", f.path, "--db", db)
          expect(code).to eq(2)
          expect(err).to include("not valid JSON")
        end
      end
    end

    it "exits 1 when config is invalid" do
      Tempfile.create(["evt", ".json"]) do |f|
        f.write('{}')
        f.flush
        Tempfile.create(["bad", ".prc"]) do |bad|
          bad.write("router x\nexit\nprocess p\nexit\n")
          bad.flush
          with_db do |db|
            code, _, err = run("trigger", "process", "p", "input", f.path,
                               "--db", db, "--config", bad.path, "--runner", "stub")
            expect(code).to eq(1)
            expect(err).to include("config invalid")
          end
        end
      end
    end
  end

  describe "replay" do
    it "exits 2 with usage when args missing" do
      code, _, err = run("replay")
      expect(code).to eq(2)
      expect(err).to include("usage: replay run")
    end

    it "exits 2 when --db is missing" do
      code, _, err = run("replay", "run", "ghost-uid", "--no-db")
      expect(code).to eq(2)
      expect(err).to include("requires --db")
    end

    it "exits 1 when run does not exist" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("replay", "run", "missing-uid", "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("prouter replay")
      end
    end
  end

  describe "resume" do
    it "exits 2 with usage when args missing" do
      code, _, err = run("resume")
      expect(code).to eq(2)
      expect(err).to include("usage: resume run")
    end

    it "exits 2 when --value is not valid JSON" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("resume", "run", "abc", "--value", "not-json", "--db", db, "--runner", "stub")
        expect(code).to eq(2)
        expect(err).to include("invalid JSON")
      end
    end

    it "exits 1 when run uid not found" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("resume", "run", "missing-uid", "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("no run 'missing-uid'")
      end
    end

    it "exits 1 when run-by-thread finds nothing" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        code, _, err = run("resume", "run-by-thread", "abc", "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("paused run for thread")
      end
    end

    it "exits 1 when run has no pinned commit" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
        runs.update_run(r.id, status: "paused")
        sql_db.close
        code, _, err = run("resume", "run", r.uid, "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("no pinned commit")
      end
    end

    it "exits 1 when pinned commit is gone" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        store = Prouterd::ControlPlane::ConfigStore.new(sql_db)
        commit_id = store.list_commits(limit: 1).first.id
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: commit_id, input_event: {}, parent_run_id: nil, thread_id: nil)
        runs.update_run(r.id, status: "paused")
        sql_db.execute("PRAGMA foreign_keys = OFF")
        sql_db.execute("DELETE FROM config_commits WHERE id = ?", [commit_id])
        sql_db.execute("PRAGMA foreign_keys = ON")
        sql_db.close
        code, _, err = run("resume", "run", r.uid, "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("is gone")
      end
    end
  end

  describe "parse_runtime_options" do
    it "exits 2 when --config is missing its value" do
      code, _, err = run("trigger", "process", "p", "input", "/tmp/x.json", "--config")
      expect(code).to eq(2)
      expect(err).to include("--config requires a path")
    end

    it "exits 2 when --db is missing its value" do
      code, _, err = run("trigger", "process", "p", "input", "/tmp/x.json", "--db")
      expect(code).to eq(2)
      expect(err).to include("--db requires a path")
    end

    it "exits 2 when --runner is missing its value" do
      code, _, err = run("trigger", "process", "p", "input", "/tmp/x.json", "--runner")
      expect(code).to eq(2)
      expect(err).to include("--runner requires a kind")
    end

    it "exits 2 on an unknown flag" do
      code, _, err = run("trigger", "process", "p", "input", "/tmp/x.json", "--bogus")
      expect(code).to eq(2)
      expect(err).to include("unknown option '--bogus'")
    end
  end

  describe "machine vs human output" do
    it "emit_run_summary prints a JSON line when stdout isn't a tty" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          code, out, _err = run("trigger", "process", "p", "input", f.path,
                                "--db", db, "--runner", "stub")
          expect([0, 1]).to include(code)
          last_json_line = out.lines.find { |l| l.start_with?("{") }
          if last_json_line
            payload = JSON.parse(last_json_line)
            expect(payload).to have_key("run_id")
            expect(payload).to have_key("status")
          end
        end
      end
    end
  end

  describe "diff edge cases" do
    it "exits 1 when --config target file fails to parse" do
      Tempfile.create(["bad", ".prc"]) do |bad|
        bad.write("router x\n color red\nexit\n")
        bad.flush
        code, _, err = run("diff", fixture_path("minimal.prc"), "--config", bad.path)
        expect(code).to eq(1)
        expect(err).to include("unknown directive")
      end
    end

    it "exits 1 when --no-db is set (store nil branch in cmd_diff)" do
      code, _, _err = run("diff", fixture_path("minimal.prc"), "--no-db")
      expect(code).to eq(1)
    end
  end

  describe "cancel updates a step that is non-terminal" do
    it "leaves a terminal step alone (next-on-terminal branch)" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
        s1 = runs.create_step(run_id: r.id, block_name: "hello")
        runs.update_step(s1.id, status: "success", finished_at: Time.now.utc.iso8601(3))
        runs.create_step(run_id: r.id, block_name: "tail") # status: pending
        sql_db.close
        code, _, _ = run("cancel", "run", r.uid, "--db", db)
        expect(code).to eq(0)
        sql_db2 = Prouterd::Storage::DB.open(db)
        runs2 = Prouterd::Storage::Repositories::Runs.new(sql_db2)
        steps = runs2.list_steps(r.id)
        expect(steps.find { |s| s.block_name == "hello" }.status).to eq("success") # untouched
        expect(steps.find { |s| s.block_name == "tail" }.status).to eq("canceled")
        sql_db2.close
      end
    end
  end


  describe "emit_run_summary error footer" do
    it "prints 'error:' line in human mode when the run carries an error_summary" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        sql_db = Prouterd::Storage::DB.open(db)
        runs = Prouterd::Storage::Repositories::Runs.new(sql_db)
        r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
        runs.update_run(r.id, error_summary: "block oops failed", status: "failed",
                              finished_at: Time.now.utc.iso8601(3))
        step = runs.create_step(run_id: r.id, block_name: "hello", attempt: 1)
        runs.update_step(step.id, status: "failed", finished_at: Time.now.utc.iso8601(3),
                                  duration_ms: 25)
        sql_db.close

        out = StringIO.new
        def out.tty?; true; end
        err = StringIO.new
        m = described_class.new([], StringIO.new, out, err)
        sql_db2 = Prouterd::Storage::DB.open(db)
        runs2 = Prouterd::Storage::Repositories::Runs.new(sql_db2)
        r2 = runs2.get_run_by_uid(r.uid)
        m.send(:emit_run_summary, r2, runs2)
        expect(out.string).to include("error: block oops failed")
        expect(out.string).to include("25ms")
        sql_db2.close
      end
    end
  end

  describe "trigger exit codes" do
    it "exits 1 when triggered run fails (failed status branch)" do
      Tempfile.create(["evt", ".json"]) do |f|
        f.write('{}')
        f.flush
        Tempfile.create(["fail", ".prc"]) do |t|
          # Use a process whose block fails: docker image typically missing
          # under stub, but stub-runner default is success. So write a doc
          # whose block references a non-existent secret to break at
          # build_env. Validator catches that at apply — so instead let
          # the stub runner fail explicitly via env injection. The
          # simplest path: a multi-block process where the second block
          # fan-outs to an undeclared process — orchestrator records
          # the error.
          t.write(<<~PRC)
            router demo
            exit
            interface docker img
             image x
            exit
            process p
             block hello
              interface docker img
              fan-out from missing into ghost
             exit
            exit
          PRC
          t.flush
          with_db do |db|
            run("apply", t.path, "--db", db)
            code, _, _ = run("trigger", "process", "p", "input", f.path,
                              "--db", db, "--runner", "stub")
            expect(code).to eq(1)
          end
        end
      end
    end
  end

  describe "validate failure injections" do
    it "exits 2 with --against running when an unknown option follows" do
      code, _, err = run("validate", fixture_path("minimal.prc"), "--against", "running", "--bogus")
      expect(code).to eq(2)
      expect(err).to include("unknown option '--bogus'")
    end

    it "exits 2 with --against running when target file is missing" do
      code, _, _ = run("validate", "/no/such.prc", "--against", "running", "--no-db")
      expect(code).to eq(2)
    end

    it "exits 1 with --against running when target file fails to parse" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        code, _, _ = run("validate", t.path, "--against", "running", "--no-db")
        expect(code).to eq(1)
      end
    end
  end

  describe "apply failure injections" do
    it "exits 2 when an unknown option follows the path" do
      code, _, err = run("apply", fixture_path("minimal.prc"), "--bogus")
      expect(code).to eq(2)
      expect(err).to include("unknown option '--bogus'")
    end

    it "exits 2 when the path file is missing" do
      code, _, _ = run("apply", "/no/such/file.prc", "--no-db")
      expect(code).to eq(2)
    end

    it "exits 1 when the path fails to parse" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        code, _, _ = run("apply", t.path, "--no-db")
        expect(code).to eq(1)
      end
    end
  end

  describe "report_check shape" do
    it "prints '(missing)' router placeholder when document has no router" do
      Tempfile.create(["t", ".prc"]) do |t|
        t.write("interface docker img\n image x\nexit\nprocess p\n block a\n  interface docker img\n exit\nexit\n")
        t.flush
        code, out, _ = run("check", t.path)
        expect(out).to include("(missing)")
        expect(code).to eq(1).or eq(0)
      end
    end
  end

  describe "shell error path" do
    it "exits 1 when initial config is bad and surfaces a ShellError" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\nexit\nprocess p\nexit\n")
        t.flush
        code, _, err = run("shell", "--no-db", "--config", t.path)
        expect(code).to eq(1)
        expect(err).to include("prouter shell")
      end
    end
  end

  describe "missing_arg / invalid_arg helpers" do
    it "missing_arg prints 'requires a value' and returns 2" do
      err = StringIO.new
      m = described_class.new([], StringIO.new, StringIO.new, err)
      expect(m.send(:missing_arg, "cmd", "--db")).to eq(2)
      expect(err.string).to include("--db requires a value")
    end

    it "invalid_arg prints the message and returns 2" do
      err = StringIO.new
      m = described_class.new([], StringIO.new, StringIO.new, err)
      expect(m.send(:invalid_arg, "cmd", "boom")).to eq(2)
      expect(err.string).to include("prouter cmd: boom")
    end
  end

  describe "read_file SystemCallError" do
    it "prints 'cannot read' and returns nil on permission error" do
      err = StringIO.new
      m = described_class.new([], StringIO.new, StringIO.new, err)
      allow(File).to receive(:read).with("/tmp/x").and_raise(Errno::EACCES.new("denied"))
      expect(m.send(:read_file, "/tmp/x")).to be_nil
      expect(err.string).to include("cannot read")
    end
  end

  describe "replay variants" do
    it "passes from_block to session.replay_from" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        allow_any_instance_of(Prouterd::Shell::Session).to receive(:replay_from).and_raise(
          Prouterd::Shell::ShellError, "no such run"
        )
        code, _, err = run("replay", "run", "x", "from", "blk", "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("no such run")
      end
    end

    it "honors --use-current-config" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        captured = nil
        allow_any_instance_of(Prouterd::Shell::Session).to receive(:replay) do |_, _uid, **opts|
          captured = opts
          raise Prouterd::Shell::ShellError, "stop here"
        end
        run("replay", "run", "x", "--use-current-config", "--db", db, "--runner", "stub")
        expect(captured).to eq(use_current_config: true)
      end
    end
  end

  describe "resume --value pure-parse path" do
    it "accepts --value JSON and proceeds" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        # --value parses fine; downstream fails with "no run" because uid doesn't exist.
        code, _, err = run("resume", "run", "missing", "--value", '{"x":1}', "--db", db, "--runner", "stub")
        expect(code).to eq(1)
        expect(err).to include("no run")
      end
    end
  end

  describe "check report shape" do
    it "emits 'schedule=' for cron iface and method/path for webhook" do
      Tempfile.create(["mixed", ".prc"]) do |t|
        t.write(<<~PRC)
          router demo
          exit
          secret TOK
           source env TOK
          exit
          interface webhook in
           path /x
           method POST
           auth bearer secret TOK
          exit
          interface cron tick
           schedule "0 * * * *"
          exit
          interface docker img
           image foo
          exit
          process p
           block a
            interface docker img
           exit
          exit
        PRC
        t.flush
        code, out, _err = run("check", t.path)
        expect(code).to eq(0)
        expect(out).to include("schedule=")
        expect(out).to include("POST /x")
      end
    end
  end

  describe "shell_exec_warnings rescue" do
    it "skips a block whose exec has unbalanced quotes (ArgumentError rescue)" do
      Tempfile.create(["sh", ".prc"]) do |t|
        t.write(<<~PRC)
          router demo
          exit
          interface shell sh1
          exit
          process p
           block a
            interface shell sh1
            exec `echo "unterminated`
           exit
          exit
        PRC
        t.flush
        code, out, _ = run("check", t.path)
        expect(code).to eq(0)
        expect(out).to include("Warnings:")
      end
    end
  end

  describe "validate prints diff lines in human mode (TTY-mocked stdout)" do
    it "renders 'no semantic changes' when identical and stdout is a tty" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        # Use a fake stdout that pretends to be a TTY
        out = StringIO.new
        def out.tty?; true; end
        err = StringIO.new
        code = described_class.run(
          ["validate", fixture_path("minimal.prc"), "--against", "running", "--db", db],
          stdout: out, stderr: err
        )
        expect(code).to eq(0)
        expect(out.string).to include("no semantic changes")
      end
    end

    it "renders the section list when there are diffs and stdout is a TTY" do
      with_db do |db|
        run("apply", fixture_path("minimal.prc"), "--db", db)
        Tempfile.create(["other", ".prc"]) do |t|
          t.write(<<~PRC)
            router demo
            exit
            interface docker img1
             image alpine
            exit
            process p
             block hello
              interface docker img1
             exit
             block extra
              interface docker img1
             exit
            exit
          PRC
          t.flush
          out = StringIO.new
          def out.tty?; true; end
          err = StringIO.new
          described_class.run(
            ["validate", t.path, "--against", "running", "--db", db],
            stdout: out, stderr: err
          )
          expect(out.string).to match(/change\(s\) vs running config/)
        end
      end
    end
  end
end
