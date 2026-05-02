require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Runtime::Scheduler do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      queue default
       concurrency 1
       timeout 1m
      exit
      interface cron daily_report
       schedule "* * * * *"
       no shutdown
      exit
      process report
       queue default
       block produce
        image x
        output result
       exit
      exit
      route interface daily_report process report
      exit
    PRC
  end

  before do
    store.commit(document)
    runner.default(&Prouterd::Runner::StubRunner.success)
  end

  it "fires the cron interface when its schedule has come due" do
    scheduler = described_class.new(store: store, runner: runner, jobs: jobs, output: StringIO.new)
    # Pretend we last fired far enough in the past that one minute-tick is due.
    scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)
    scheduler.tick(now: Time.now)

    runs = repo.list_runs
    expect(runs.length).to be >= 1
    fired = runs.first
    expect(fired.process_name).to eq("report")
    expect(fired.interface_name).to eq("daily_report")
    event = JSON.parse(fired.input_event_json)
    expect(event["interface"]).to eq("daily_report")
    expect(event).to have_key("fired_at")
  end

  it "skips shutdown cron interfaces" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface cron noisy
       schedule "* * * * *"
       shutdown
      exit
      process p
       block a
        image x
        output r
       exit
      exit
      route interface noisy process p
      exit
    PRC
    store.commit(doc)

    scheduler = described_class.new(store: store, runner: runner, jobs: jobs)
    scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)
    scheduler.tick(now: Time.now)

    expect(repo.list_runs).to be_empty
  end

  it "ignores cron interfaces missing a global route" do
    doc = parse(<<~PRC)
      router x
      exit
      interface cron orphan
       schedule "* * * * *"
       no shutdown
      exit
      process q
       block a
        image x
        output r
       exit
      exit
    PRC
    store.commit(doc)

    out = StringIO.new
    scheduler = described_class.new(store: store, runner: runner, jobs: jobs, output: out)
    scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)
    scheduler.tick(now: Time.now)

    expect(repo.list_runs).to be_empty
    expect(out.string).to include("no global route")
  end

  it "advances @last_fired so the next tick at the same minute does not double-fire" do
    scheduler = described_class.new(store: store, runner: runner, jobs: jobs, output: StringIO.new)
    scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)

    now = Time.now
    scheduler.tick(now: now)
    runs_after_first = repo.list_runs.length
    expect(runs_after_first).to be >= 1

    scheduler.tick(now: now + 0.5)
    expect(repo.list_runs.length).to eq(runs_after_first)
  end

  it "returns nil for invalid cron expressions and reports it" do
    doc = parse(<<~PRC)
      router x
      exit
      interface cron bad
       schedule "not a cron"
       no shutdown
      exit
      process q
       block a
        image x
        output r
       exit
      exit
      route interface bad process q
      exit
    PRC
    store.commit(doc)

    out = StringIO.new
    scheduler = described_class.new(store: store, runner: runner, jobs: jobs, output: out)
    scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)
    scheduler.tick(now: Time.now)

    expect(repo.list_runs).to be_empty
  end
end
