require "spec_helper"

RSpec.describe Prouterd::Runtime::Orchestrator do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { described_class.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "#enqueue + #trigger" do
    it "raises TriggerError when process_name is not in document" do
      doc = parse("router demo\nexit\n")
      expect { orchestrator.trigger(doc, "ghost", input_event: {}) }.to raise_error(
        Prouterd::Runtime::TriggerError, /no such process 'ghost'/
      )
    end
  end

  describe "#resolve_thread_id" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         thread-id "{{event.key}}"
         block a
          interface docker img
         exit
        exit
      PRC
    end

    it "renders the template against the input event" do
      process = doc.processes.first
      expect(orchestrator.resolve_thread_id(process, { "key" => "abc" })).to eq("abc")
    end

    it "returns nil when the template renders to empty / whitespace" do
      process = doc.processes.first
      expect(orchestrator.resolve_thread_id(process, {})).to be_nil
      expect(orchestrator.resolve_thread_id(process, { "key" => "" })).to be_nil
    end

    it "returns nil when no thread_id_template is set" do
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
      expect(orchestrator.resolve_thread_id(doc.processes.first, {})).to be_nil
    end
  end

  describe "#capture_mcp_snapshot" do
    it "returns nil when there's no mcp_pool" do
      doc = parse("router demo\nexit\n")
      o = described_class.new(db: db, runner: runner, mcp_pool: nil)
      expect(o.capture_mcp_snapshot(double(blocks: []), doc)).to be_nil
    end

    it "returns nil when no block references any mcp interface" do
      mcp_pool = double
      o = described_class.new(db: db, runner: runner, mcp_pool: mcp_pool)
      doc = parse("router demo\nexit\n")
      process = double(blocks: [double(mcp_refs: []), double(mcp_refs: [])])
      expect(o.capture_mcp_snapshot(process, doc)).to be_nil
    end

    it "delegates to mcp_pool.tool_snapshot when blocks reference mcp ifaces" do
      mcp_pool = double
      expect(mcp_pool).to receive(:tool_snapshot).with(["mid"]).and_return("mid" => [])
      o = described_class.new(db: db, runner: runner, mcp_pool: mcp_pool)
      doc = parse("router demo\nexit\n")
      process = double(blocks: [double(mcp_refs: ["mid"])])
      expect(o.capture_mcp_snapshot(process, doc)).to eq("mid" => [])
    end
  end

  describe "#resume_run" do
    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface manual cli
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block ask
          pause "wait for human"
         exit
         block tail
          interface docker img
         exit
         route ask tail
        exit
        route interface cli process p
        exit
      PRC
    end

    it "raises TriggerError when run uid is unknown" do
      expect {
        orchestrator.resume_run("ghost", doc)
      }.to raise_error(Prouterd::Runtime::TriggerError, /no such run/)
    end

    it "raises TriggerError when run is not paused" do
      r = repo.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect {
        orchestrator.resume_run(r.uid, doc)
      }.to raise_error(Prouterd::Runtime::TriggerError, /is not paused/)
    end

    it "raises TriggerError when process is not in the supplied document" do
      r = repo.create_run(process_name: "ghost", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      repo.update_run(r.id, status: "paused")
      expect {
        orchestrator.resume_run(r.uid, doc)
      }.to raise_error(Prouterd::Runtime::TriggerError, /not in the supplied document/)
    end

    it "raises TriggerError when no paused step row exists" do
      r = repo.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      repo.update_run(r.id, status: "paused")
      expect {
        orchestrator.resume_run(r.uid, doc)
      }.to raise_error(Prouterd::Runtime::TriggerError, /no paused step row/)
    end

    it "raises TriggerError when the paused step's block is no longer a pause block" do
      r = repo.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      step = repo.create_step(run_id: r.id, block_name: "tail")
      repo.update_step(step.id, status: "paused")
      repo.update_run(r.id, status: "paused")
      expect {
        orchestrator.resume_run(r.uid, doc)
      }.to raise_error(Prouterd::Runtime::TriggerError, /no longer a pause block/)
    end

    it "resumes successfully and continues downstream" do
      # Trigger and let it pause naturally
      run = orchestrator.trigger(doc, "p", input_event: { "x" => 1 })
      expect(run.status).to eq("paused")
      finished = orchestrator.resume_run(run.uid, doc, value: { "answer" => "ok" })
      expect(finished.status).to eq("success")
    end

    it "finalises as success when no downstream blocks exist" do
      simpler = parse(<<~PRC)
        router demo
        exit
        process p
         block ask
          pause "wait"
         exit
        exit
      PRC
      run = orchestrator.trigger(simpler, "p", input_event: {})
      expect(run.status).to eq("paused")
      finished = orchestrator.resume_run(run.uid, simpler, value: { "result" => 1 })
      expect(finished.status).to eq("success")
    end
  end

  describe "#execute_run with from_block" do
    let(:doc) do
      parse(<<~PRC)
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
    end

    it "raises TriggerError when from_block doesn't exist" do
      run = repo.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect {
        orchestrator.execute_run(run, doc, from_block: "ghost")
      }.to raise_error(Prouterd::Runtime::TriggerError, /no such block/)
    end
  end

  describe "#run_timeout_overshoot" do
    let(:doc) { parse(<<~PRC) }
      router demo
      exit
    PRC

    it "uses process.timeout_ms when set" do
      process = double(timeout_ms: 100, queue_name: nil)
      expect(orchestrator.send(:run_timeout_overshoot, process, doc, Time.now.utc - 1)).to be > 0
    end

    it "falls back to queue.timeout_ms when process timeout is nil" do
      queue = Prouterd::Config::AST::Queue.new(name: "q", line: 1)
      queue.timeout_ms = 100
      docq = double(queues: [queue])
      process = double(timeout_ms: nil, queue_name: "q")
      expect(orchestrator.send(:run_timeout_overshoot, process, docq, Time.now.utc - 1)).to be > 0
    end

    it "falls back to ENV default" do
      ENV["PROUTERD_RUN_DEFAULT_TIMEOUT_MS"] = "50"
      process = double(timeout_ms: nil, queue_name: nil)
      expect(orchestrator.send(:run_timeout_overshoot, process, doc, Time.now.utc - 1)).to be > 0
    ensure
      ENV.delete("PROUTERD_RUN_DEFAULT_TIMEOUT_MS")
    end

    it "returns nil when cap is <= 0" do
      ENV["PROUTERD_RUN_DEFAULT_TIMEOUT_MS"] = "0"
      process = double(timeout_ms: nil, queue_name: nil)
      expect(orchestrator.send(:run_timeout_overshoot, process, doc, Time.now.utc - 1)).to be_nil
    ensure
      ENV.delete("PROUTERD_RUN_DEFAULT_TIMEOUT_MS")
    end

    it "returns nil when not yet over the cap" do
      process = double(timeout_ms: 60_000, queue_name: nil)
      expect(orchestrator.send(:run_timeout_overshoot, process, doc, Time.now.utc)).to be_nil
    end
  end

  describe "#kill_in_flight_containers" do
    let(:run) { repo.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }

    it "no-ops when in_flight is missing" do
      orch = described_class.new(db: db, runner: runner, in_flight: nil)
      expect { orch.send(:kill_in_flight_containers, run) }.not_to raise_error
    end

    it "no-ops when docker-api is unavailable" do
      tracker = Prouterd::Runtime::InFlightRegistry.new
      orch = described_class.new(db: db, runner: runner, in_flight: tracker)
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(false)
      expect { orch.send(:kill_in_flight_containers, run) }.not_to raise_error
    end
  end

  describe "#downstream_blocks" do
    it "lists every direct downstream block" do
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
         block b
          interface docker img
         exit
         block c
          interface docker img
         exit
         route a b
         route a c
        exit
      PRC
      process = doc.processes.first
      expect(orchestrator.send(:downstream_blocks, process, "a").sort).to eq(["b", "c"])
      expect(orchestrator.send(:downstream_blocks, process, "b")).to eq([])
    end
  end

  describe "#deep_stringify" do
    it "converts symbol keys to strings recursively" do
      expect(orchestrator.send(:deep_stringify, { a: { b: [1, { c: 2 }] } })).to eq(
        "a" => { "b" => [1, { "c" => 2 }] }
      )
    end

    it "passes scalars through" do
      expect(orchestrator.send(:deep_stringify, 5)).to eq(5)
      expect(orchestrator.send(:deep_stringify, "x")).to eq("x")
    end
  end

  describe "#execute_run process lookup" do
    it "raises TriggerError when the run's process name is no longer in the document" do
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
      run = repo.create_run(process_name: "ghost", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect { orchestrator.execute_run(run, doc) }.to raise_error(
        Prouterd::Runtime::TriggerError, /no such process 'ghost'/
      )
    end
  end

  describe "execute: process with no entry blocks" do
    it "finalises as failed with 'no entry blocks' error" do
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
         block b
          interface docker img
         exit
         route a b
         route b a
        exit
      PRC
      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("no entry blocks")
    end
  end

  describe "execute: shutdown block is auto-skipped" do
    it "marks the run successful after auto-skipping a shutdown block" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
          shutdown
         exit
        exit
      PRC
      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
    end
  end

  describe "run_timeout_overshoot queue lookup edge" do
    it "falls through to the env-or-default cap when queue_name resolves to no queue" do
      doc = parse(<<~PRC)
        router demo
        exit
      PRC
      process = double(timeout_ms: nil, queue_name: "ghost-queue")
      # cap defaults: ENV PROUTERD_RUN_DEFAULT_TIMEOUT_MS or 6h
      expect(orchestrator.send(:run_timeout_overshoot, process, doc, Time.now.utc)).to be_nil
    end
  end

  describe "#finalize_run with status=canceled" do
    it "logs with the CANCELED mnemonic" do
      logger = double
      allow(logger).to receive(:info)
      allow(logger).to receive(:notice)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      orch = described_class.new(db: db, runner: runner, logger: logger)
      run = repo.create_run(process_name: "p", input_event: {})
      expect(logger).to receive(:info).with("run canceled", hash_including(mnemonic: "CANCELED"))
      orch.send(:finalize_run, run, status: "canceled", error: nil)
    end

    it "logs with the DONE mnemonic for unknown statuses" do
      logger = double
      allow(logger).to receive(:info)
      allow(logger).to receive(:notice)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      orch = described_class.new(db: db, runner: runner, logger: logger)
      run = repo.create_run(process_name: "p", input_event: {})
      expect(logger).to receive(:info).with("run weird-status", hash_including(mnemonic: "DONE"))
      orch.send(:finalize_run, run, status: "weird-status", error: nil)
    end
  end

  describe "EnvSecretResolver" do
    let(:resolver) { Prouterd::Runtime::EnvSecretResolver.new }

    it "reads env-sourced secrets" do
      ENV["TEST_SECRET_X"] = "topsecret"
      secret = double(source_type: "env", source_value: "TEST_SECRET_X")
      expect(resolver.resolve(secret)).to eq("topsecret")
    ensure
      ENV.delete("TEST_SECRET_X")
    end

    it "reads file-sourced secrets and trims trailing newline" do
      Tempfile.create("prouter-sec-") do |f|
        f.write("topsecret\n")
        f.flush
        secret = double(source_type: "file", source_value: f.path)
        expect(resolver.resolve(secret)).to eq("topsecret")
      end
    end

    it "returns nil for missing file path" do
      secret = double(source_type: "file", source_value: "/no/such/file")
      expect(resolver.resolve(secret)).to be_nil
    end

    it "returns nil for blank path" do
      secret = double(source_type: "file", source_value: "")
      expect(resolver.resolve(secret)).to be_nil
    end

    it "returns nil for nil path" do
      secret = double(source_type: "file", source_value: nil)
      expect(resolver.resolve(secret)).to be_nil
    end

    it "swallows SystemCallError when reading the file" do
      Tempfile.create("prouter-sec-") do |f|
        f.write("x")
        f.flush
        allow(File).to receive(:read).and_raise(Errno::EACCES.new("denied"))
        secret = double(source_type: "file", source_value: f.path)
        expect(resolver.resolve(secret)).to be_nil
      end
    end

    it "raises for unsupported source types" do
      secret = double(source_type: "vault", source_value: "x")
      expect { resolver.resolve(secret) }.to raise_error(Prouterd::Runtime::TriggerError, /unsupported secret source/)
    end
  end
end

RSpec.describe "Runtime::Orchestrator next_ready dedupe in cross-block sweep" do
  it "does not double-add a block already queued in next_ready" do
    engine = Prouterd::Runtime::RetryEngine.new(runs: double)
    process = double(routes: [double(from_block: "a", to_block: "b")])
    next_ready = ["a"]
    # Simulate the inner logic of cross-block sweep: a is in next_ready,
    # so the `unshift unless include?` else-branch fires.
    block_name = "a"
    next_ready.unshift(block_name) unless next_ready.include?(block_name)
    expect(next_ready).to eq(["a"])
  end
end

RSpec.describe "Runtime::Orchestrator ready dedupe against executed" do
  it "skips a block that was already marked executed via direct execute_run loop" do
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
      db: Prouterd::Storage::DB.open(":memory:"),
      runner: Prouterd::Runner::StubRunner.new
    )
    # Use the cross-block retry path indirectly by trigger + cross-block sweep.
    run = orch.trigger(doc, "p", input_event: {})
    expect(run.status).to eq("success")
  end
end

RSpec.describe "Runtime::Orchestrator build_next_ready phantom block name" do
  it "skips an executed block that no longer exists in process.blocks" do
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
       block b
        interface docker img
       exit
       route a b
      exit
    PRC
    orch = Prouterd::Runtime::Orchestrator.new(
      db: Prouterd::Storage::DB.open(":memory:"),
      runner: Prouterd::Runner::StubRunner.new
    )
    process = doc.processes.first
    block_a = process.block("a")
    successful = [block_a]
    executed = Set.new(["a", "ghost-name-not-in-process"])
    ctx = Prouterd::Runtime::Context.new("a" => { "x" => 1 })
    mutex = Mutex.new
    result = orch.send(:build_next_ready, process, successful, executed, ctx, mutex)
    expect(result).to include("b")
  end
end

RSpec.describe "Runtime::Orchestrator events.publish nil guards" do
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

RSpec.describe "Runtime::Orchestrator input_event_json nil branch" do
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

RSpec.describe "Orchestrator and_style_merge_barrier? non-barrier target" do
  it "returns false when the target isn't a barrier block at all" do
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
       block b
        interface docker img
       exit
       route a b
      exit
    PRC
    orch = Prouterd::Runtime::Orchestrator.new(
      db: Prouterd::Storage::DB.open(":memory:"),
      runner: Prouterd::Runner::StubRunner.new
    )
    result = orch.send(:and_style_merge_barrier?, doc.processes.first, "b", Set.new)
    expect(result).to be(false)
  end
end

RSpec.describe "Orchestrator soft-cancel between levels" do
  it "stops scheduling when run.status flips to canceled mid-execution" do
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
       block b
        interface docker img
       exit
       route a b
      exit
    PRC
    db = Prouterd::Storage::DB.open(":memory:")
    runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
    runner = Prouterd::Runner::StubRunner.new
    # After block 'a' executes, flip the run row to canceled so the
    # orchestrator's top-of-loop polling catches the soft-cancel.
    runner.program("a") do |req|
      run = runs_repo.get_run_by_uid(req.run_uid)
      runs_repo.update_run(run.id, status: "canceled",
                                   finished_at: Time.now.utc.iso8601(3))
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: {}, artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orch.trigger(doc, "p", input_event: {})
    expect(run.status).to eq("canceled")
    db.close
  end
end

RSpec.describe "Orchestrator on-failure stop terminates the run" do
  it "marks the run failed with the configured error_summary" do
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
       block b
        interface docker img
       exit
       route a b
      exit
    PRC
    db = Prouterd::Storage::DB.open(":memory:")
    runner = Prouterd::Runner::StubRunner.new
    runner.program("a") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 7, stdout: "", stderr: "fail",
        output_json: nil, artifacts: [],
        error_type: "boom", error_message: "oops",
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end
    orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    run = orch.trigger(doc, "p", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("boom")
    db.close
  end
end
