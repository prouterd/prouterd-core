require "spec_helper"

# Phase 37i: block-level `fan-out from <path> into <process>`.
RSpec.describe "fan-out into another process" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_FAN = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_FAN + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process poller
       block search
        interface docker img1
        fan-out from issues into analyze
       exit
      exit
      process analyze
       thread-id "{{event.key}}"
       block do
        interface docker img1
       exit
      exit
    PRC
  end

  it "enqueues one child run per array element after the source block succeeds" do
    runner.program("search") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "issues" => [{ "key" => "K-1" }, { "key" => "K-2" }, { "key" => "K-3" }] },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    parent = orchestrator.trigger(document, "poller", input_event: {})
    expect(parent.status).to eq("success")

    children = repo.list_runs(process_name: "analyze")
    expect(children.length).to eq(3)
    expect(children.map(&:thread_id)).to contain_exactly("K-1", "K-2", "K-3")
    expect(children.map(&:status).uniq).to eq(["queued"])
    expect(children.map(&:parent_run_id).uniq).to eq([parent.id])
  end

  it "no-ops gracefully when the path resolves to a non-array" do
    runner.program("search") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "issues" => "not-an-array" },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    parent = orchestrator.trigger(document, "poller", input_event: {})
    expect(parent.status).to eq("success")
    expect(repo.list_runs(process_name: "analyze")).to be_empty
  end

  it "wraps scalar items into {value, index} when the array is non-Hash" do
    runner.program("search") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "issues" => ["a", "b"] },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    orchestrator.trigger(document, "poller", input_event: {})
    children = repo.list_runs(process_name: "analyze")
    expect(children.length).to eq(2)
    events = children.map { |r| JSON.parse(r.input_event_json) }.sort_by { |e| e["index"] }
    expect(events).to eq([{ "value" => "a", "index" => 0 }, { "value" => "b", "index" => 1 }])
  end
end
