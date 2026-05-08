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

  it "applies `map` clauses to project + filter+strip-prefix item fields" do
    map_doc = parse(<<~PRC)
      router demo
      exit
      process poller
       block search
        interface docker img1
        fan-out from issues into analyze
         map ticket from issue.key
         map labels from issue.labels filter starts-with("repo:") strip-prefix
        exit
       exit
      exit
      process analyze
       block do
        interface docker img1
       exit
      exit
    PRC
    runner.program("search") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "issues" => [
          { "issue" => { "key" => "K-1", "labels" => ["repo:a", "team:x", "repo:b"] } },
          { "issue" => { "key" => "K-2", "labels" => ["team:y"] } }
        ] },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    orchestrator.trigger(map_doc, "poller", input_event: {})
    children = repo.list_runs(process_name: "analyze")
    events = children.map { |r| JSON.parse(r.input_event_json) }.sort_by { |e| e["ticket"] }
    expect(events.first).to include("ticket" => "K-1", "labels" => %w[a b])
    expect(events.last).to include("ticket" => "K-2", "labels" => [])
  end

  it "skips a child when `dedupe` matches a recent prior-run by thread_id" do
    dedupe_doc = parse(<<~PRC)
      router demo
      exit
      process poller
       block search
        interface docker img1
        fan-out from issues into analyze
         map ticket from key
         dedupe by ticket window 1h when prior-run.status eq "success"
        exit
       exit
      exit
      process analyze
       thread-id "{{event.ticket}}"
       block do
        interface docker img1
       exit
      exit
    PRC
    runner.program("do",     &Prouterd::Runner::StubRunner.success)
    runner.program("search") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "issues" => [{ "key" => "SCT-1" }, { "key" => "SCT-2" }] },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    # Pre-seed a successful run for SCT-1 via direct repo create →
    # dedupe should drop it next time.
    repo.create_run(
      process_name: "analyze",
      input_event: { "ticket" => "SCT-1" },
      thread_id: "SCT-1"
    ).then do |seed|
      repo.update_run(seed.id, status: "success", finished_at: Time.now.utc.iso8601(3))
    end

    orchestrator.trigger(dedupe_doc, "poller", input_event: {})
    fresh_children = repo.list_runs(process_name: "analyze")
                          .reject { |r| r.status == "success" }  # exclude the seed
    expect(fresh_children.map(&:thread_id)).to contain_exactly("SCT-2")
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
