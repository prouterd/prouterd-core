require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe "Phase 9 cancel + diff" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def drive(script, session: nil)
    session ||= Prouterd::Shell::Session.new(store: store, runner: runner)
    input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
    output = StringIO.new
    error  = StringIO.new
    Prouterd::Shell::Shell.run(
      session: session,
      input: input, output: output, error: error,
      interactive: false, banner: false
    )
    [output.string, error.string]
  end

  describe "cancel run" do
    it "marks a non-terminal run as canceled" do
      doc = parse("router x\nexit\ninterface docker img1\n image x\nexit\nprocess p\n block a\n  interface docker img1\n exit\nexit\n")
      store.commit(doc)

      repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = repo.create_run(process_name: "p", input_event: {})
      repo.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))
      repo.create_step(run_id: run.id, block_name: "a")
      step = repo.list_steps(run.id).first
      repo.update_step(step.id, status: "running")

      out, _err = drive("enable\ncancel run #{run.uid}\nexit\n")
      expect(out).to include("Cancelled run")

      refreshed = repo.get_run(run.id)
      expect(refreshed.status).to eq("canceled")
      expect(refreshed.error_summary).to eq("canceled by operator")

      step_after = repo.get_step(step.id)
      expect(step_after.status).to eq("canceled")
    end

    it "refuses to cancel a finished run" do
      doc = parse("router x\nexit\ninterface docker img1\n image x\nexit\nprocess p\n block a\n  interface docker img1\n exit\nexit\n")
      store.commit(doc)
      repo = Prouterd::Storage::Repositories::Runs.new(db)
      run = repo.create_run(process_name: "p", input_event: {})
      repo.update_run(run.id, status: "success", finished_at: Time.now.utc.iso8601(3))

      _out, err = drive("enable\ncancel run #{run.uid}\nexit\n")
      expect(err).to include("already success")
    end

    it "errors on unknown run uid" do
      _out, err = drive("enable\ncancel run run_deadbeef\nexit\n")
      expect(err).to include("no such run")
    end
  end

  describe "orchestrator soft-cancel between levels" do
    it "aborts when run.status flips to canceled mid-execution" do
      doc = parse(<<~PRC)
        router x
        exit
        interface docker img1
         image x
        exit
        process p
         block a
          interface docker img1
         exit
         block b
          interface docker img1
         exit
         route a b
        exit
      PRC

      orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      repo = Prouterd::Storage::Repositories::Runs.new(db)

      runner.program("a") do |req|
        # While block 'a' is running, simulate operator cancellation.
        repo.update_run(
          repo.list_runs.first.id,
          status: "canceled",
          finished_at: Time.now.utc.iso8601(3),
          error_summary: "canceled by operator"
        )
        Prouterd::Runner::StubRunner.success(output: { "x" => 1 }).call(req)
      end
      runner.program("b", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("canceled")
      # Block 'b' should NOT have executed.
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to eq(["a"])
    end
  end

  describe "diff <file> running-config" do
    it "shows nothing on identical input" do
      doc = parse("router demo\nexit\n")
      store.commit(doc)

      Tempfile.create(["same", ".prc"]) do |tmp|
        tmp.write("router demo\nexit\n")
        tmp.flush
        out, _err = drive("enable\ndiff #{tmp.path} running-config\nexit\n")
        expect(out).to include("No changes.")
      end
    end

    it "shows added/removed lines on a real change" do
      base = parse("router demo\nexit\n")
      store.commit(base)

      Tempfile.create(["new", ".prc"]) do |tmp|
        tmp.write(<<~PRC)
          router demo
          exit
          queue default
           concurrency 4
           timeout 1m
          exit
        PRC
        tmp.flush
        out, _err = drive("enable\ndiff #{tmp.path} running-config\nexit\n")
        expect(out).to match(/^\+/)
        expect(out).to include("queue default")
      end
    end

    it "errors when file is missing" do
      base = parse("router demo\nexit\n")
      store.commit(base)
      _out, err = drive("enable\ndiff /nope/missing.prc running-config\nexit\n")
      expect(err).to include("no such file")
    end
  end
end
