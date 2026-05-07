require "spec_helper"

RSpec.describe "process-level thread-id" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_THREAD = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_THREAD + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process per_ticket
       thread-id "{{event.ticket}}"
       block fetch
        interface docker img1
       exit
      exit
    PRC
  end

  it "resolves the template against the input event and persists into runs.thread_id" do
    runner.program("fetch", &Prouterd::Runner::StubRunner.success)
    run = orchestrator.trigger(document, "per_ticket",
                               input_event: { "ticket" => "SCT-1234" })
    expect(run.thread_id).to eq("SCT-1234")

    fetched = repo.get_run_by_uid(run.uid)
    expect(fetched.thread_id).to eq("SCT-1234")
  end

  it "treats an empty rendered template as nil (no per-thread pinning)" do
    runner.program("fetch", &Prouterd::Runner::StubRunner.success)
    run = orchestrator.trigger(document, "per_ticket", input_event: {})
    expect(run.thread_id).to be_nil
  end

  it "filters list_runs by thread_id" do
    runner.program("fetch", &Prouterd::Runner::StubRunner.success)
    orchestrator.trigger(document, "per_ticket", input_event: { "ticket" => "SCT-1" })
    orchestrator.trigger(document, "per_ticket", input_event: { "ticket" => "SCT-2" })
    orchestrator.trigger(document, "per_ticket", input_event: { "ticket" => "SCT-1" })

    sct1 = repo.list_runs(thread_id: "SCT-1")
    expect(sct1.length).to eq(2)
    expect(sct1.map(&:thread_id).uniq).to eq(["SCT-1"])
  end

  it "leaves thread_id nil for processes without a template" do
    plain = parse(<<~PRC)
      router demo
      exit
      process p
       block fetch
        interface docker img1
       exit
      exit
    PRC
    runner.program("fetch", &Prouterd::Runner::StubRunner.success)
    run = orchestrator.trigger(plain, "p", input_event: { "x" => 1 })
    expect(run.thread_id).to be_nil
  end
end
