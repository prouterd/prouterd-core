require "spec_helper"

RSpec.describe Prouterd::Runtime::FanOut do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
  let(:logs_repo) { Prouterd::Storage::Repositories::Runs.new(db) }
  after { db.close }

  IFACES_FAN_COV = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_FAN_COV + prc))
  end

  describe "target process missing" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process poller
         block search
          interface docker img1
          fan-out from issues into ghost
         exit
        exit
      PRC
    end

    it "logs a system warning and does NOT raise (line 32/35 branch)" do
      runner.program("search") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: { "issues" => [{ "key" => "K-1" }] },
          artifacts: [], error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end

      parent = orchestrator.trigger(document, "poller", input_event: {})
      expect(parent.status).to eq("success")

      logs = repo.list_logs(parent.id).select { |l| l.stream == "system" }.map(&:content).join("\n")
      expect(logs).to match(/target process 'ghost' not declared/)
    end
  end

  describe "rate-limit staggers child available_at" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process poller
         block search
          interface docker img1
          fan-out from issues into analyze
           rate-limit 1/2s
          exit
         exit
        exit
        process analyze
         block do
          interface docker img1
         exit
        exit
      PRC
    end

    it "spaces children's available_at by the window when N=1" do
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

      jobs = db.execute("SELECT available_at FROM jobs ORDER BY id").map(&:first)
      expect(jobs.length).to eq(3)
      times = jobs.map { |s| Time.iso8601(s) }
      # The 2nd should be ~2s later than the 1st; the 3rd ~4s after the 1st.
      expect(times[1] - times[0]).to be_within(0.6).of(2.0)
      expect(times[2] - times[0]).to be_within(1.2).of(4.0)
    end
  end

  describe "empty array of items (line 45 early return)" do
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
         block do
          interface docker img1
         exit
        exit
      PRC
    end

    it "no children enqueued when the source array is empty" do
      runner.program("search") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: { "issues" => [] },
          artifacts: [], error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end

      orchestrator.trigger(document, "poller", input_event: {})
      expect(repo.list_runs(process_name: "analyze")).to be_empty
    end
  end

  describe "dedupe with no thread_id (line 122 early return)" do
    let(:document) do
      # No `thread-id` directive on analyze, so children get no thread_id.
      # The dedupe still runs but always falls through (early return false).
      parse(<<~PRC)
        router demo
        exit
        process poller
         block search
          interface docker img1
          fan-out from issues into analyze
           map ticket from key
           dedupe by ticket window 1h
          exit
         exit
        exit
        process analyze
         block do
          interface docker img1
         exit
        exit
      PRC
    end

    it "treats missing thread_id as not-a-dedupe-candidate (no skips)" do
      runner.program("search") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: { "issues" => [{ "key" => "K-1" }, { "key" => "K-1" }] },
          artifacts: [], error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end

      orchestrator.trigger(document, "poller", input_event: {})
      children = repo.list_runs(process_name: "analyze")
      # Both children enqueued since neither has a thread_id.
      expect(children.length).to eq(2)
    end
  end

  describe "dedupe with prior run OUTSIDE the window" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process poller
         block search
          interface docker img1
          fan-out from issues into analyze
           map ticket from key
           dedupe by ticket window 1h
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
    end

    it "does NOT dedupe a child when the only prior run is older than the window" do
      # Plant a stale prior analyze run with the same thread_id but
      # created_at 2 hours ago — past the 1h dedupe window.
      stale = repo.create_run(process_name: "analyze", input_event: { "ticket" => "K-1" },
                              parent_run_id: nil, thread_id: "K-1")
      db.execute("UPDATE runs SET created_at = ? WHERE id = ?",
                 [(Time.now.utc - 7200).iso8601(3), stale.id])

      runner.program("search") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: { "issues" => [{ "key" => "K-1" }] },
          artifacts: [], error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end

      orchestrator.trigger(document, "poller", input_event: {})
      children = repo.list_runs(process_name: "analyze")
      # 1 stale + 1 fresh child — dedupe didn't fire because the prior
      # run is past the cutoff.
      expect(children.length).to eq(2)
    end
  end
end
