require "spec_helper"
require "stringio"

# Behaviour spec for the optional-`fugit` story (Phase 28).
#
# When fugit isn't installed, the daemon's Scheduler must keep running.
# Cron interfaces simply never fire; a single warning logs once at the
# first cron interface seen. interface webhook / interface manual stay
# unaffected.
RSpec.describe Prouterd::Runtime::Scheduler do
  describe "when fugit is unavailable" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }
    let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }

    after { db.close }

    around do |example|
      original = Prouterd::Runtime::Scheduler.instance_variable_get(:@fugit_available)
      Prouterd::Runtime::Scheduler.instance_variable_set(:@fugit_available, false)
      example.run
      Prouterd::Runtime::Scheduler.instance_variable_set(:@fugit_available, original)
    end

    it "warns once at first cron interface and disables firing" do
      doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
        router demo
        exit
        interface cron daily
         schedule "* * * * *"
         no shutdown
        exit
        interface docker img1
         image x
        exit
        process p
         block a
          interface docker img1
         exit
        exit
        route interface daily process p
        exit
      PRC
      store.commit(doc)

      out = StringIO.new
      scheduler = described_class.new(store: store, runner: runner, jobs: jobs,
                                      logger: Prouterd::Logger.build(out))
      scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)

      # Two ticks; the warning should appear exactly once across both.
      scheduler.tick(now: Time.now)
      scheduler.tick(now: Time.now)

      expect(out.string).to include("'fugit' gem not installed")
      expect(out.string.scan(/'fugit' gem not installed/).length).to eq(1)
      expect(repo.list_runs).to be_empty
    end
  end
end
