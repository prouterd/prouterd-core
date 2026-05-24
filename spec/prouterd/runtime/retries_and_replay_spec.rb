require "spec_helper"

RSpec.describe "Phase 6: retries, on-failure, dead-letter, replay" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  RETRIES_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(RETRIES_IFACES + prc))
  end

  describe "retry policies" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        policy r3_fixed
         retry attempts 3
         retry backoff fixed
         retry initial-delay 1ms
         retry max-delay 1ms
        exit
        process p
         block flaky
          interface docker img1
          retry policy r3_fixed
         exit
        exit
      PRC
    end

    it "retries up to attempts and succeeds eventually" do
      attempts_seen = 0
      runner.default do |req|
        attempts_seen += 1
        if attempts_seen < 3
          Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit").call(req)
        else
          Prouterd::Runner::StubRunner.success(output: { "ok" => true }).call(req)
        end
      end

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")
      steps = repo.list_steps(run.id)
      expect(steps.length).to eq(3)
      expect(steps.map(&:attempt)).to eq([1, 2, 3])
      expect(steps.map(&:status)).to eq(%w[failed failed success])
    end

    it "passes the current attempt through PROUTER_ATTEMPT" do
      attempts_seen = []
      runner.default do |req|
        attempts_seen << req.env["PROUTER_ATTEMPT"]
        if attempts_seen.length < 3
          Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit").call(req)
        else
          Prouterd::Runner::StubRunner.success.call(req)
        end
      end

      run = orchestrator.trigger(document, "p", input_event: {})

      expect(run.status).to eq("success")
      expect(attempts_seen).to eq(%w[1 2 3])
    end

    it "fails the run when all retries exhaust" do
      runner.default(&Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))
      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("failed")
      steps = repo.list_steps(run.id)
      expect(steps.length).to eq(3)
      expect(steps.map(&:status)).to all(eq("failed"))
      expect(run.error_summary).to include("non_zero_exit")
    end

    it "logs each retry to run_logs" do
      attempts_seen = 0
      runner.default do |req|
        attempts_seen += 1
        if attempts_seen < 2
          Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit").call(req)
        else
          Prouterd::Runner::StubRunner.success.call(req)
        end
      end

      run = orchestrator.trigger(document, "p", input_event: {})
      logs = repo.list_logs(run.id)
      system_logs = logs.select { |l| l.stream == "system" && l.content.include?("retrying") }
      expect(system_logs.length).to eq(1)
      expect(system_logs.first.content).to include("attempt 2/3")
    end
  end

  describe "on-failure continue" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block start
          interface docker img1
         exit
         block flaky
          interface docker img1
         exit
         block survivor
          interface docker img1
         exit
         block downstream_of_survivor
          interface docker img1
         exit
         route start flaky
          on-failure continue
         exit
         route start survivor
         route survivor downstream_of_survivor
        exit
      PRC
    end

    it "lets the run succeed when a 'continue' branch fails" do
      runner.program("start",                     &Prouterd::Runner::StubRunner.success(output: { "go" => 1 }))
      runner.program("flaky",                     &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))
      runner.program("survivor",                  &Prouterd::Runner::StubRunner.success(output: { "ok" => 1 }))
      runner.program("downstream_of_survivor",    &Prouterd::Runner::StubRunner.success(output: { "done" => 1 }))

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to contain_exactly("start", "flaky", "survivor", "downstream_of_survivor")
    end

    it "still fails the run when a 'stop' branch fails (default policy)" do
      doc = parse(<<~PRC)
        router demo
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

      runner.program("a", &Prouterd::Runner::StubRunner.success)
      runner.program("b", &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("'b'")
    end
  end

  describe "show dead-letter" do
    it "lists only failed runs" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block a
          interface docker img1
         exit
        exit
      PRC
      store.commit(doc)

      runner.default(&Prouterd::Runner::StubRunner.success)
      orchestrator.trigger(doc, "p", input_event: {}, commit_id: store.running_commit.id)

      runner.default(&Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))
      orchestrator.trigger(doc, "p", input_event: {}, commit_id: store.running_commit.id)

      failed = repo.list_runs(status: "failed")
      expect(failed.length).to eq(1)
      expect(failed.first.status).to eq("failed")
    end
  end

  describe "replay" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block a
          interface docker img1
         exit
        exit
      PRC
    end

    it "creates a new run with the same input event and a replay_of pointer" do
      store.commit(document)
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "result" => 1 }))

      original = orchestrator.trigger(document, "p", input_event: { "payload" => "x" }, commit_id: store.running_commit.id)
      session = Prouterd::Shell::Session.new(store: store, runner: runner)
      replayed = session.replay(original.uid)

      expect(replayed.uid).not_to eq(original.uid)
      expect(replayed.replay_of_run_id).to eq(original.id)
      expect(replayed.status).to eq("success")
      expect(JSON.parse(replayed.input_event_json)).to eq("payload" => "x")
    end

    it "uses the historical commit even after the running config has changed" do
      store.commit(document)

      broken = parse(<<~PRC)
        router demo
        exit
        process p
         block a
          interface docker img1
         exit
         block extra
          interface docker img1
         exit
         route a extra
        exit
      PRC
      store.commit(broken)

      runner.default(&Prouterd::Runner::StubRunner.success)
      original = orchestrator.trigger(document, "p", input_event: { "payload" => "x" }, commit_id: 1)

      session = Prouterd::Shell::Session.new(store: store, runner: runner)
      replayed = session.replay(original.uid)

      executed = repo.list_steps(replayed.id).map(&:block_name)
      expect(executed).to eq(["a"])
    end

    it "errors when the original run has no pinned commit" do
      runner.default(&Prouterd::Runner::StubRunner.success)
      original = orchestrator.trigger(document, "p", input_event: {})

      session = Prouterd::Shell::Session.new(store: store, runner: runner)
      expect { session.replay(original.uid) }
        .to raise_error(Prouterd::Shell::ShellError, /not pinned to a config commit/)
    end

    it "errors on unknown run uid" do
      session = Prouterd::Shell::Session.new(store: store, runner: runner)
      expect { session.replay("run_deadbeef") }
        .to raise_error(Prouterd::Shell::ShellError, /no such run/)
    end
  end
end
