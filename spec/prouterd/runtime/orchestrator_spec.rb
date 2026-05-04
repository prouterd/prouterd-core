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

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      interface docker img2
       image alpine:2
      exit
      interface docker img3
       image alpine:3
      exit
      process p
       block extract
        interface docker img1
       exit
       block enrich
        interface docker img2
       exit
       block notify
        interface docker img3
       exit
       route extract enrich
       route enrich notify
      exit
    PRC
  end

  it "runs the full DAG when every block returns success" do
    runner.program("extract") do |req|
      expect(req.input_json["context"]["event"]["body"]).to eq("hello")
      Prouterd::Runner::StubRunner.success(output: { "name" => "raw-data" }).call(req)
    end
    runner.program("enrich") do |req|
      expect(req.input_json["context"]["extract"]).to eq({ "name" => "raw-data" })
      Prouterd::Runner::StubRunner.success(output: { "score" => 87 }).call(req)
    end
    runner.program("notify") { |req| Prouterd::Runner::StubRunner.success(output: { "ok" => true }).call(req) }

    run = orchestrator.trigger(document, "p", input_event: { "body" => "hello" })

    expect(run.status).to eq("success")
    steps = repo.list_steps(run.id)
    expect(steps.map(&:block_name)).to eq(%w[extract enrich notify])
    expect(steps.map(&:status)).to all(eq("success"))
    expect(runner.calls.map(&:block_name)).to eq(%w[extract enrich notify])
  end

  it "stops the run on a block failure" do
    runner.program("extract", &Prouterd::Runner::StubRunner.success(output: { "x" => 1 }))
    runner.program("enrich", &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))

    run = orchestrator.trigger(document, "p", input_event: {})

    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("enrich")
    expect(run.error_summary).to include("non_zero_exit")
    expect(runner.calls.map(&:block_name)).to eq(%w[extract enrich])
    statuses = repo.list_steps(run.id).map(&:status)
    expect(statuses).to eq(%w[success failed])
  end

  it "raises when triggering an unknown process" do
    expect { orchestrator.trigger(document, "missing", input_event: {}) }
      .to raise_error(Prouterd::Runtime::TriggerError, /no such process/)
  end

  it "passes secrets via env" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      secret CLEARBIT_API_KEY
       source env CLEARBIT_API_KEY
      exit
      process p
       block enrich
        interface docker img1
        secret CLEARBIT_API_KEY
       exit
      exit
    PRC

    captured = nil
    runner.default { |req| captured = req; Prouterd::Runner::StubRunner.success.call(req) }

    ENV["CLEARBIT_API_KEY"] = "secret-value-xyz"
    begin
      orchestrator.trigger(doc, "p", input_event: {})
    ensure
      ENV.delete("CLEARBIT_API_KEY")
    end

    expect(captured.env["CLEARBIT_API_KEY"]).to eq("secret-value-xyz")
    expect(captured.env["PROUTER_BLOCK_NAME"]).to eq("enrich")
    expect(captured.env["PROUTER_INPUT_PATH"]).to eq("/prouter/input.json")
  end

  it "fans out to multiple downstream blocks (sequential queue)" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      process fan
       block start
        interface docker img1
       exit
       block left
        interface docker img1
       exit
       block right
        interface docker img1
       exit
       route start left
       route start right
      exit
    PRC
    runner.default(&Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(doc, "fan", input_event: {})
    blocks = repo.list_steps(run.id).map(&:block_name)
    expect(blocks).to contain_exactly("start", "left", "right")
    expect(run.status).to eq("success")
  end

  it "writes block output back to context auto-keyed by block name" do
    runner.program("extract", &Prouterd::Runner::StubRunner.success(output: { "name" => "Acme" }))
    runner.program("enrich") do |req|
      expect(req.input_json["context"]["extract"]).to eq({ "name" => "Acme" })
      Prouterd::Runner::StubRunner.success(output: { "score" => 99 }).call(req)
    end
    runner.program("notify") do |req|
      expect(req.input_json["context"]["enrich"]).to eq({ "score" => 99 })
      Prouterd::Runner::StubRunner.success.call(req)
    end

    run = orchestrator.trigger(document, "p", input_event: { "body" => "x" })
    expect(run.status).to eq("success")
  end

  it "captures stdout/stderr into run_logs" do
    runner.program("extract") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0,
        stdout: "extracted!\n",
        stderr: "warn: something\n",
        output_json: { "ok" => true },
        artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    runner.program("enrich", &Prouterd::Runner::StubRunner.success)
    runner.program("notify", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    logs = repo.list_logs(run.id)
    streams = logs.map(&:stream)
    expect(streams).to include("stdout", "stderr")
    expect(logs.find { |l| l.stream == "stdout" }.content).to eq("extracted!\n")
  end

  describe "events emission" do
    let(:bus) { Prouterd::Events.new }
    let(:orchestrator) { described_class.new(db: db, runner: runner, events: bus) }

    it "publishes the run / step / log lifecycle through the injected bus" do
      received = Hash.new { |h, k| h[k] = [] }
      %i[run_created run_updated step_created step_updated log_appended].each do |topic|
        bus.subscribe(topic) { |t, payload| received[t] << payload }
      end

      runner.program("extract", &Prouterd::Runner::StubRunner.success)
      runner.program("enrich",  &Prouterd::Runner::StubRunner.success)
      runner.program("notify",  &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: { "type" => "x" })

      expect(received[:run_created].size).to eq(1)
      expect(received[:run_created].first[:run].uid).to eq(run.uid)
      expect(received[:run_created].first[:run].status).to eq("queued")
      expect(received[:run_updated]).not_to be_empty
      expect(received[:run_updated].last[:run].status).to eq("success")

      expect(received[:step_created].size).to eq(3)
      expect(received[:step_created].first).to include(:step, :run_id, :run_uid)
      expect(received[:step_created].first[:run_uid]).to eq(run.uid)

      expect(received[:step_updated].size).to be >= 6
      finished = received[:step_updated].select { |p| p[:step].status == "success" }
      expect(finished.size).to eq(3)
    end

    it "publishes log_appended for stdout / stderr captured from the runner" do
      received = []
      bus.subscribe(:log_appended) { |_, payload| received << payload }

      runner.default { |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "hello\n", stderr: "warn\n",
          output_json: { "ok" => true }, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      }

      orchestrator.trigger(document, "p", input_event: {})

      streams = received.map { |p| p[:stream] }
      expect(streams).to include("stdout", "stderr")
      contents = received.map { |p| p[:content] }
      expect(contents.find { |c| c.include?("hello") }).not_to be_nil
    end

    it "defaults to the process-wide singleton when no bus is injected" do
      orchestrator_default = described_class.new(db: db, runner: runner)
      received = []
      handle = Prouterd::Events.subscribe(:run_created) { |_, p| received << p }
      runner.default(&Prouterd::Runner::StubRunner.success)
      orchestrator_default.trigger(document, "p", input_event: {})
      expect(received).not_to be_empty
    ensure
      Prouterd::Events.unsubscribe(handle) if handle
    end
  end
end
