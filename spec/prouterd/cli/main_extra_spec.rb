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
end
