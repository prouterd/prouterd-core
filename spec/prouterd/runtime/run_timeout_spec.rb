require "spec_helper"

# Phase 35b: run-level wall-clock timeout. Per-block and per-queue
# timeouts already exist; what was missing is a cap on the run AS A
# WHOLE — long DAG × retries × slowly-dying blocks could hang a run
# indefinitely. New `process timeout <duration>` directive enforces a
# wall-clock cutoff in the orchestrator's between-level loop.
RSpec.describe "Phase 35b run-level wall-clock timeout" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  it "fails the run with run_timeout marker when the cap is exceeded" do
    document = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process slow
       timeout 100ms
       block a
        interface shell host
        exec "true"
       exit
       block b
        interface shell host
        exec "true"
       exit
       route a b
      exit
      route interface cli process slow
      exit
    PRC

    runner.program("a") do |req|
      sleep 0.25 # >100ms cap
      Prouterd::Runner::StubRunner.success.call(req)
    end
    runner.program("b", &Prouterd::Runner::StubRunner.success)

    run = orchestrator.trigger(document, "slow", input_event: {})
    expect(run.status).to eq("failed")
    expect(run.error_summary).to include("run_timeout")

    logs = repo.list_logs(run.id).select { |l| l.stream == "system" }
    expect(logs.map(&:content).join("\n")).to include("wall-clock timeout")
  end

  it "DSL roundtrip preserves process.timeout" do
    src = <<~PRC
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       timeout 5s
       block a
        interface shell host
       exit
      exit
      route interface cli process p
      exit
    PRC

    doc = parse(src)
    expect(doc.processes.first.timeout_ms).to eq(5000)
    rendered = Prouterd::Config::Renderer.render(doc)
    expect(rendered).to include("timeout 5s")
    second = Prouterd::Config::Renderer.render(parse(rendered))
    expect(second).to eq(rendered)
  end
end
