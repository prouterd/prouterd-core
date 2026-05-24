require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe Prouterd::Shell::Modes::Privileged do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:session) { Prouterd::Shell::Session.new(store: store) }
  let(:mode) { described_class.new }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def tokens(line)
    Prouterd::Shell::CommandLine.tokenize(line)
  end

  describe "#cmd_show" do
    it "raises with syntax message when no target supplied" do
      expect { mode.cmd_show(tokens("show"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: show/
      )
    end

    it "dispatches to Show.execute for a known target" do
      session.replace_running(parse(<<~PRC))
        router demo
        exit
      PRC
      mode.cmd_show(tokens("show version"), session, out, err)
      expect(out.string).to include("prouter")
    end
  end

  describe "#cmd_load" do
    it "raises on wrong arity" do
      expect { mode.cmd_load(tokens("load"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: load/
      )
    end

    it "raises a CommandError when file is missing" do
      expect {
        mode.cmd_load(tokens("load /no/such/file.prc"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such file/)
    end

    it "raises a CommandError on parse errors" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        expect {
          mode.cmd_load(tokens("load #{t.path}"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /load failed/)
      end
    end

    it "raises a CommandError on validation failure and prints per-error lines" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\nexit\nprocess p\nexit\n")
        t.flush
        expect {
          mode.cmd_load(tokens("load #{t.path}"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /load failed/)
        expect(out.string).to include("has no blocks")
      end
    end

    it "loads a valid file and replaces running config" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_load(tokens("load #{t.path}"), session, out, err)
        expect(out.string).to match(/Loaded .* processes, \d+ interfaces/)
        expect(session.running_config.router.name).to eq("demo")
      end
    end
  end

  describe "#cmd_apply" do
    it "raises on wrong arity" do
      expect { mode.cmd_apply(tokens("apply"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: apply/
      )
    end

    it "raises when file is missing" do
      expect {
        mode.cmd_apply(tokens("apply /no/such/file.prc"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such file/)
    end

    it "raises on parse errors" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\n color red\nexit\n")
        t.flush
        expect {
          mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /apply failed/)
      end
    end

    it "raises on validation failure" do
      Tempfile.create(["bad", ".prc"]) do |t|
        t.write("router x\nexit\nprocess p\nexit\n")
        t.flush
        expect {
          mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /apply failed/)
      end
    end

    it "commits a valid file when DB is attached" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
        expect(out.string).to match(/Applied .* as commit \d+/)
      end
    end

    it "loads in-memory when no DB is attached" do
      bare = Prouterd::Shell::Session.new(store: nil)
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), bare, out, err)
        expect(out.string).to include("no DB attached; not persisted")
      end
    end
  end

  describe "#cmd_write / #cmd_copy" do
    it "write rejects wrong arity" do
      expect { mode.cmd_write(tokens("write"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: write memory/
      )
    end

    it "write rejects wrong sub-token" do
      expect { mode.cmd_write(tokens("write foo"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: write memory/
      )
    end

    it "write memory raises when no DB attached" do
      bare = Prouterd::Shell::Session.new(store: nil)
      expect { mode.cmd_write(tokens("write memory"), bare, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /no DB attached/
      )
    end

    it "copy rejects wrong arity" do
      expect { mode.cmd_copy(tokens("copy"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: copy running-config startup-config/
      )
    end

    it "copy rejects wrong keywords" do
      expect { mode.cmd_copy(tokens("copy foo bar"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: copy running-config startup-config/
      )
    end

    it "write memory raises CommandError when no startup pointer exists" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      out2 = StringIO.new
      mode.cmd_write(tokens("write memory"), session, out2, err)
      expect(out2.string).to include("Startup configuration saved")
    end

    it "copy running-config startup-config is equivalent to write memory" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      out2 = StringIO.new
      mode.cmd_copy(tokens("copy running-config startup-config"), session, out2, err)
      expect(out2.string).to include("Startup configuration saved")
    end

    it "write memory wraps ConfigStoreError" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      allow(session).to receive(:write_memory).and_raise(
        Prouterd::ControlPlane::ConfigStoreError, "boom"
      )
      expect {
        mode.cmd_write(tokens("write memory"), session, StringIO.new, err)
      }.to raise_error(Prouterd::Shell::CommandError, /boom/)
    end
  end

  describe "#cmd_rollback" do
    it "rejects wrong arity" do
      expect { mode.cmd_rollback(tokens("rollback"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: rollback/
      )
    end

    it "rejects wrong subtoken" do
      expect { mode.cmd_rollback(tokens("rollback foo 1"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: rollback/
      )
    end

    it "rejects when no DB attached" do
      bare = Prouterd::Shell::Session.new(store: nil)
      expect {
        mode.cmd_rollback(tokens("rollback commit 1"), bare, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no DB attached/)
    end

    it "rejects when commit id is not an integer" do
      expect {
        mode.cmd_rollback(tokens("rollback commit abc"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /commit id must be an integer/)
    end

    it "wraps ConfigStoreError" do
      allow(session).to receive(:rollback_to).and_raise(
        Prouterd::ControlPlane::ConfigStoreError, "no such commit"
      )
      expect {
        mode.cmd_rollback(tokens("rollback commit 999"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such commit/)
    end

    it "succeeds with a valid commit id" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      Tempfile.create(["good2", ".prc"]) do |t|
        t.write("router demo\nexit\n")
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, StringIO.new, err)
      end
      out2 = StringIO.new
      mode.cmd_rollback(tokens("rollback commit 1"), session, out2, err)
      expect(out2.string).to match(/Rolled back .* commit 1/)
    end
  end

  describe "#cmd_trigger" do
    it "rejects wrong arity" do
      expect { mode.cmd_trigger(tokens("trigger"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: trigger process/
      )
    end

    it "raises when input file is missing" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      expect {
        mode.cmd_trigger(tokens("trigger process p input /no/such.json"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such input file/)
    end

    it "raises on invalid JSON" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      Tempfile.create(["evt", ".json"]) do |t|
        t.write("not-json")
        t.flush
        expect {
          mode.cmd_trigger(tokens("trigger process p input #{t.path}"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /not valid JSON/)
      end
    end

    it "wraps TriggerError" do
      session_with_runner = Prouterd::Shell::Session.new(
        store: store, runner: Prouterd::Runner::StubRunner.new
      )
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session_with_runner, out, err)
      end
      Tempfile.create(["evt", ".json"]) do |t|
        t.write('{}')
        t.flush
        allow_any_instance_of(Prouterd::Runtime::Orchestrator).to receive(:trigger).and_raise(
          Prouterd::Runtime::TriggerError, "no such process"
        )
        expect {
          mode.cmd_trigger(tokens("trigger process p input #{t.path}"), session_with_runner, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /no such process/)
      end
    end
  end

  describe "#cmd_replay" do
    it "rejects malformed syntax" do
      expect { mode.cmd_replay(tokens("replay"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: replay/
      )
    end

    it "rejects wrong keyword in 5-token form" do
      expect {
        mode.cmd_replay(tokens("replay run abc fromm b"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: replay/)
    end

    it "wraps ShellError from session.replay" do
      allow(session).to receive(:replay).and_raise(Prouterd::Shell::ShellError, "no such run")
      expect {
        mode.cmd_replay(tokens("replay run ghost"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such run/)
    end

    it "supports the from-form" do
      allow(session).to receive(:replay_from).and_return(double(uid: "new", status: "success", id: 1, error_summary: nil))
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(double(list_steps: []))
      mode.cmd_replay(tokens("replay run abc from blk"), session, out, err)
      expect(out.string).to include("Replayed abc as new (success)")
    end

    it "renders per-step duration + error footer when the replayed run has them" do
      step = double(block_name: "extract", status: "failed", duration_ms: 42)
      run  = double(uid: "new", status: "failed", id: 1, error_summary: "block extract crashed")
      allow(session).to receive(:replay).and_return(run)
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(double(list_steps: [step]))

      mode.cmd_replay(tokens("replay run abc"), session, out, err)
      expect(out.string).to include("Replayed abc as new (failed)")
      expect(out.string).to include("extract")
      expect(out.string).to include("42ms")
      expect(out.string).to include("error: block extract crashed")
    end

    it "prints '-' for a step with no duration_ms" do
      step = double(block_name: "extract", status: "queued", duration_ms: nil)
      run  = double(uid: "new", status: "success", id: 1, error_summary: nil)
      allow(session).to receive(:replay).and_return(run)
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(double(list_steps: [step]))

      mode.cmd_replay(tokens("replay run abc"), session, out, err)
      expect(out.string).to match(/extract\s+queued\s+-/)
    end
  end

  describe "#cmd_trigger commit_id pass-through" do
    it "passes nil commit_id when session.store has no running pointer" do
      Tempfile.create(["evt", ".json"]) do |t|
        t.write('{"x":1}')
        t.flush
        # build a session with a runner but NO commit applied yet
        session_no_running = Prouterd::Shell::Session.new(store: store, runner: Prouterd::Runner::StubRunner.new)
        session_no_running.replace_running(
          Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
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
        )
        # store has no running_commit yet — `session.store.running_commit` returns nil.
        captured = nil
        allow_any_instance_of(Prouterd::Runtime::Orchestrator).to receive(:trigger) do |_orch, _doc, _name, **kwargs|
          captured = kwargs
          double(uid: "x", status: "success", id: 1, error_summary: nil)
        end
        allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(double(list_steps: []))
        mode.cmd_trigger(tokens("trigger process p input #{t.path}"), session_no_running, out, err)
        expect(captured[:commit_id]).to be_nil
      end
    end
  end

  describe "#cmd_cancel" do
    it "rejects wrong syntax" do
      expect { mode.cmd_cancel(tokens("cancel"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: cancel run/
      )
    end

    it "rejects when no DB attached" do
      bare = Prouterd::Shell::Session.new(store: nil)
      expect {
        mode.cmd_cancel(tokens("cancel run abc"), bare, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no DB attached/)
    end

    it "rejects unknown run uid" do
      expect {
        mode.cmd_cancel(tokens("cancel run abc"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /no such run/)
    end

    it "rejects already-terminal run" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      runs.update_run(r.id, status: "success", finished_at: Time.now.utc.iso8601(3))
      expect {
        mode.cmd_cancel(tokens("cancel run #{r.uid}"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /already success/)
    end

    it "marks the run + non-terminal steps as canceled" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      runs.create_step(run_id: r.id, block_name: "a")
      mode.cmd_cancel(tokens("cancel run #{r.uid}"), session, out, err)
      expect(out.string).to include("Cancelled run #{r.uid}")
    end

    it "leaves a terminal step alone while canceling the pending one" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      done = runs.create_step(run_id: r.id, block_name: "done")
      runs.update_step(done.id, status: "success", finished_at: Time.now.utc.iso8601(3))
      runs.create_step(run_id: r.id, block_name: "pending")
      mode.cmd_cancel(tokens("cancel run #{r.uid}"), session, out, err)
      steps = runs.list_steps(r.id)
      expect(steps.find { |s| s.block_name == "done" }.status).to eq("success")
      expect(steps.find { |s| s.block_name == "pending" }.status).to eq("canceled")
    end
  end

  describe "#cmd_diff" do
    it "rejects wrong syntax" do
      expect { mode.cmd_diff(tokens("diff"), session, out, err) }.to raise_error(
        Prouterd::Shell::CommandError, /syntax: diff/
      )
    end

    it "delegates to Show.diff_file_against_running" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        mode.cmd_apply(tokens("apply #{t.path}"), session, out, err)
      end
      expect(Prouterd::Shell::Show).to receive(:diff_file_against_running)
      mode.cmd_diff(tokens("diff /tmp/x.prc running-config"), session, out, err)
    end
  end

  describe "#cmd_disable / #cmd_exit / #cmd_help" do
    it "disable returns :exit" do
      expect(mode.cmd_disable(tokens("disable"), session, out, err)).to eq(:exit)
    end

    it "exit returns :quit" do
      expect(mode.cmd_exit(tokens("exit"), session, out, err)).to eq(:quit)
    end

    it "help prints command list" do
      mode.cmd_help(tokens("help"), session, out, err)
      expect(out.string).to include("Privileged mode commands")
      expect(out.string).to include("rollback commit")
    end
  end

  describe "prompt suffix" do
    it "is '#'" do
      expect(mode.prompt_suffix).to eq("#")
    end
  end
end
