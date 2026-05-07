require "spec_helper"

RSpec.describe "block-level skip-when" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES + prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       block fetch
        interface docker img1
       exit
       block enrich
        interface docker img1
        skip-when fetch.empty eq true
       exit
       block notify
        interface docker img1
       exit
       route fetch enrich
       route enrich notify
      exit
    PRC
  end

  it "skips the block (with synthetic step + downstream propagation) when the predicate matches" do
    runner.program("fetch", &Prouterd::Runner::StubRunner.success(output: { "empty" => true }))
    runner.program("enrich", &Prouterd::Runner::StubRunner.success)
    runner.program("notify", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    steps = repo.list_steps(run.id)
    by_block = steps.group_by(&:block_name).transform_values(&:first)

    expect(by_block.keys).to contain_exactly("fetch", "enrich", "notify")
    expect(by_block["enrich"].status).to eq("skipped")
    expect(JSON.parse(by_block["enrich"].output_json)).to eq("skipped" => true)
    expect(by_block["notify"].status).to eq("success")
    expect(run.status).to eq("success")
  end

  it "executes the block normally when the predicate does not match" do
    runner.program("fetch", &Prouterd::Runner::StubRunner.success(output: { "empty" => false }))
    runner.program("enrich", &Prouterd::Runner::StubRunner.success(output: { "ok" => 1 }))
    runner.program("notify", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "p", input_event: {})
    steps = repo.list_steps(run.id)
    enrich = steps.find { |s| s.block_name == "enrich" }

    expect(enrich.status).to eq("success")
    expect(JSON.parse(enrich.output_json)).to eq("ok" => 1)
    expect(run.status).to eq("success")
  end
end
