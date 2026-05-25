require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

# Covers tick_loop/tick_with_rescue, the dispatch unrouted-process /
# shutdown-process / match-fail branches, auto-pull execution for
# `interface local_repo`, and dispatch happy path with timezone.
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

  describe ".fugit_available?" do
    after { described_class.instance_variable_set(:@fugit_available, nil) }

    it "returns false when require raises LoadError" do
      described_class.instance_variable_set(:@fugit_available, nil)
      allow(described_class).to receive(:require).with("fugit").and_raise(LoadError)
      expect(described_class.fugit_available?).to be(false)
    end

    it "caches the answer" do
      described_class.instance_variable_set(:@fugit_available, true)
      expect(described_class).not_to receive(:require)
      expect(described_class.fugit_available?).to be(true)
    end
  end

  describe "#dispatch with no running_commit / no metrics" do
    it "passes commit_id: nil to enqueue when store has no running pointer" do
      document = parse(<<~PRC)
        router demo
        exit
        interface manual cli
         no shutdown
        exit
        interface cron daily
         schedule "* * * * *"
         no shutdown
        exit
        interface docker img
         image x
        exit
        process p
         block hello
          interface docker img
         exit
        exit
        route interface daily process p
        exit
      PRC
      allow(store).to receive(:load_running).and_return(document)
      allow(store).to receive(:running_commit).and_return(nil)
      # No metrics: argument omitted on scheduler ctor.
      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                   logger: Prouterd::NullLogger.new)
      iface = document.interfaces.find { |i| i.name == "daily" }
      sched.send(:dispatch, iface, document, Time.now.utc)

      latest = repo.list_runs(process_name: "p", limit: 1).first
      expect(latest.process_config_commit_id).to be_nil
    end
  end

  describe "#parse_cron error rescue" do
    it "returns nil and logs warning on invalid cron expression" do
      sched = described_class.new(store: store, runner: runner, jobs: jobs)
      iface = double(name: "i", type_fields: { "schedule" => "not-a-valid-cron", "timezone" => nil })
      expect(sched.send(:parse_cron, iface)).to be_nil
    end

    it "returns nil immediately when the iface has no schedule field" do
      sched = described_class.new(store: store, runner: runner, jobs: jobs)
      iface = double(name: "no-sched", type_fields: {})
      expect(sched.send(:parse_cron, iface)).to be_nil
    end
  end

  describe "#run_auto_pull whitelist-empty short-circuit" do
    it "returns without touching the filesystem when whitelist is empty" do
      sched = described_class.new(store: store, runner: runner, jobs: jobs)
      iface = double(name: "lr", type_fields: { "root" => "/tmp", "whitelist" => "" })
      expect(Open3).not_to receive(:capture3)
      sched.send(:run_auto_pull, iface)
    end

    it "returns without touching the filesystem when root is empty" do
      sched = described_class.new(store: store, runner: runner, jobs: jobs)
      iface = double(name: "lr", type_fields: { "root" => "", "whitelist" => "a,b" })
      expect(Open3).not_to receive(:capture3)
      sched.send(:run_auto_pull, iface)
    end
  end

  describe "tick_loop / tick_with_rescue (background thread body)" do
    let(:document) do
      parse(<<~PRC)
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
    end
    before { store.commit(document) }

    it "tick_loop body invokes tick once and then exits via @stopping" do
      scheduler = described_class.new(store: store, runner: runner, jobs: jobs,
                                      logger: Prouterd::NullLogger.new)
      # Stub sleep to flip @stopping AFTER the first iteration so the
      # loop terminates without running for real seconds. tick_loop
      # checks @stopping at the top of each iteration.
      allow(scheduler).to receive(:sleep) { scheduler.stop }
      expect(scheduler).to receive(:tick_with_rescue).at_least(:once).and_call_original

      # Pretend we last fired in the past so the tick fires at least once.
      scheduler.instance_variable_set(:@last_fired_warm, Time.now - 120)

      scheduler.tick_loop
      expect(repo.list_runs.length).to be >= 1
    end

    it "tick_with_rescue logs SCHED-TICK_ERR when tick raises" do
      out = StringIO.new
      scheduler = described_class.new(store: store, runner: runner, jobs: jobs,
                                      logger: Prouterd::Logger.build(out))
      allow(scheduler).to receive(:tick).and_raise(StandardError, "boom")
      scheduler.tick_with_rescue
      expect(out.string).to match(/TICK_ERR/)
      expect(out.string).to match(/boom/)
    end

    it "run() spawns a thread that runs warmup + tick_loop" do
      scheduler = described_class.new(store: store, runner: runner, jobs: jobs,
                                      logger: Prouterd::NullLogger.new)
      # Stub Thread.new so the body executes synchronously in the
      # spec thread, with sleep flipping stop after the first tick.
      allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
      allow(scheduler).to receive(:sleep) { scheduler.stop }
      scheduler.run
      expect(scheduler.instance_variable_get(:@last_fired_warm)).not_to be_nil
    end
  end

  describe "dispatch corner cases" do
    it "warns when the global route targets an unknown process" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface cron g
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
        route interface g process p
        exit
      PRC
      store.commit(doc)

      # Mutate the in-memory document so the route now references a
      # process that does not exist. Builder validation would refuse,
      # so we go behind it.
      doc.global_routes.first.instance_variable_set(:@process_name, "ghost")
      allow(store).to receive(:load_running).and_return(doc)

      out = StringIO.new
      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                  logger: Prouterd::Logger.build(out))
      sched.instance_variable_set(:@last_fired_warm, Time.now - 120)
      sched.tick(now: Time.now)

      expect(repo.list_runs).to be_empty
      expect(out.string).to match(/CRON_UNKNOWN_PROC/)
    end

    it "skips fires whose target process is shutdown" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface cron g
         schedule "* * * * *"
         no shutdown
        exit
        interface docker img1
         image x
        exit
        process p
         shutdown
         block a
          interface docker img1
         exit
        exit
        route interface g process p
        exit
      PRC
      store.commit(doc)

      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                  logger: Prouterd::NullLogger.new)
      sched.instance_variable_set(:@last_fired_warm, Time.now - 120)
      sched.tick(now: Time.now)
      expect(repo.list_runs).to be_empty
    end

    it "respects global-route match filter, dropping events that fail" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface cron g
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
        route interface g process p
         match event.interface eq "different"
        exit
      PRC
      store.commit(doc)

      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                  logger: Prouterd::NullLogger.new)
      sched.instance_variable_set(:@last_fired_warm, Time.now - 120)
      sched.tick(now: Time.now)
      expect(repo.list_runs).to be_empty
    end

    it "appends timezone to the cron expression for parse_cron" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface cron g
         schedule "* * * * *"
         timezone "Europe/Berlin"
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
        route interface g process p
        exit
      PRC
      store.commit(doc)

      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                  logger: Prouterd::NullLogger.new)
      sched.instance_variable_set(:@last_fired_warm, Time.now - 120)
      sched.tick(now: Time.now)
      expect(repo.list_runs.length).to be >= 1
    end
  end

  describe "auto-pull for interface local_repo" do
    before { Prouterd::Iface::LocalRepoStatus.reset! }
    after  { Prouterd::Iface::LocalRepoStatus.reset! }

    def make_git_repo(root, name)
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir) do
        system("git init -q .", out: File::NULL, err: File::NULL)
        File.write("README", "hi\n")
        system("git add -A && git -c user.email=x@y -c user.name=x commit -q -m init",
               out: File::NULL, err: File::NULL)
      end
      dir
    end

    it "executes git pull, logs PULL_OK, records LocalRepoStatus" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
           auto-pull 1ms
          exit
        PRC
        store.commit(doc)

        # Mock Open3 so we don't depend on a real upstream / network.
        status_double = instance_double(Process::Status, success?: true, exitstatus: 0)
        allow(Open3).to receive(:capture3)
          .with("git", "-C", anything, "pull", "--ff-only")
          .and_return(["Already up to date.\n", "", status_double])

        out = StringIO.new
        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::Logger.build(out))

        allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
        sched.tick(now: Time.now)
        expect(out.string).to match(/PULL_OK/)
        snap = Prouterd::Iface::LocalRepoStatus.snapshot(iface_name: "r")
        expect(snap.first.ok).to be(true)
      end
    end

    it "logs PULL_FAILED when git pull exits non-zero" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
           auto-pull 1ms
          exit
        PRC
        store.commit(doc)

        status_double = instance_double(Process::Status, success?: false, exitstatus: 128)
        allow(Open3).to receive(:capture3)
          .with("git", "-C", anything, "pull", "--ff-only")
          .and_return(["", "fatal: not a git checkout\n", status_double])

        out = StringIO.new
        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::Logger.build(out))
        allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
        sched.tick(now: Time.now)
        expect(out.string).to match(/PULL_FAILED/)
        snap = Prouterd::Iface::LocalRepoStatus.snapshot(iface_name: "r")
        expect(snap.first.ok).to be(false)
      end
    end

    it "logs NOT_GIT and skips a whitelisted entry that's not a git checkout" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "not_a_repo"))

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist not_a_repo
           auto-pull 1ms
          exit
        PRC
        store.commit(doc)

        out = StringIO.new
        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::Logger.build(out))
        allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
        sched.tick(now: Time.now)
        expect(out.string).to match(/NOT_GIT/)
        snap = Prouterd::Iface::LocalRepoStatus.snapshot(iface_name: "r")
        expect(snap.first.ok).to be(false)
      end
    end

    it "rescues StandardError in run_auto_pull and records the failure" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
           auto-pull 1ms
          exit
        PRC
        store.commit(doc)

        allow(Open3).to receive(:capture3).and_raise(StandardError, "kernel-level boom")

        out = StringIO.new
        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::Logger.build(out))
        allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
        sched.tick(now: Time.now)
        expect(out.string).to match(/PULL_ERR/)
      end
    end

    it "spaces auto-pull invocations using the cadence" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
           auto-pull 1h
          exit
        PRC
        store.commit(doc)

        called = 0
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        allow(Open3).to receive(:capture3) do
          called += 1
          ["Already up to date.\n", "", status]
        end

        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::NullLogger.new)
        allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
        now = Time.now
        sched.tick(now: now)
        sched.tick(now: now + 1) # within 1h cadence — should NOT fire again
        expect(called).to eq(1)
      end
    end

    it "warns once when auto-pull cadence is an invalid duration" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")

        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
           auto-pull not-a-duration
          exit
        PRC
        store.commit(doc)

        out = StringIO.new
        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::Logger.build(out))
        sched.tick(now: Time.now)
        sched.tick(now: Time.now)
        expect(out.string).to match(/AUTOPULL_BAD/)
        # Warning emitted exactly once across both ticks.
        expect(out.string.scan(/AUTOPULL_BAD/).length).to eq(1)
      end
    end

    it "is a no-op when whitelist resolves to nothing usable" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface local_repo r
         root /nope/does-not-exist
         whitelist some_repo
         auto-pull 1ms
        exit
      PRC
      store.commit(doc)

      out = StringIO.new
      sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                  logger: Prouterd::Logger.build(out))
      allow(Thread).to receive(:new).and_yield.and_return(double("Thread"))
      sched.tick(now: Time.now)
      # The whitelist entry isn't a git checkout — logs NOT_GIT.
      expect(out.string).to match(/NOT_GIT/)
    end

    it "skips local_repo without auto-pull set" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")
        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           root #{root}
           whitelist repo1
          exit
        PRC
        store.commit(doc)

        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::NullLogger.new)
        expect(Open3).not_to receive(:capture3)
        sched.tick(now: Time.now)
      end
    end

    it "skips shutdown local_repo interfaces" do
      Dir.mktmpdir do |root|
        make_git_repo(root, "repo1")
        doc = parse(<<~PRC)
          router demo
          exit
          interface local_repo r
           shutdown
           root #{root}
           whitelist repo1
           auto-pull 1ms
          exit
        PRC
        store.commit(doc)

        sched = described_class.new(store: store, runner: runner, jobs: jobs,
                                    logger: Prouterd::NullLogger.new)
        expect(Open3).not_to receive(:capture3)
        sched.tick(now: Time.now)
      end
    end
  end
end

RSpec.describe "Runtime::Scheduler tick safety break" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "breaks the per-iface tick loop when fugit returns the same next_time twice" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface cron daily
       schedule "* * * * *"
       no shutdown
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
      route interface daily process p
      exit
    PRC
    store.commit(doc)
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      logger: Prouterd::NullLogger.new
    )
    # Stub parse_cron to return a fake cron whose #next_time always
    # returns the same Time in the past — forces the loop's `break if
    # next_at == last` safety branch on iteration 2.
    stuck_at = Time.now.utc - 60
    stuck_at.define_singleton_method(:to_t) { self }
    fake_cron = Object.new
    fake_cron.define_singleton_method(:next_time) { |_| stuck_at }
    allow(sched).to receive(:parse_cron).and_return(fake_cron)
    sched.send(:tick, now: Time.now.utc)
  end
end

RSpec.describe "Runtime::Scheduler invalid cron rescue lines" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "logs CRON_INVALID + returns nil when Fugit.parse_cron raises" do
    require "fugit"
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      logger: (logger = double).tap { |l| allow(l).to receive(:warn) }
    )
    allow(Fugit).to receive(:parse_cron).and_raise(StandardError, "bad cron")
    iface = double(name: "i", type_fields: { "schedule" => "garbage", "timezone" => nil })
    expect(logger).to receive(:warn).with("invalid cron expression", hash_including(mnemonic: "CRON_INVALID"))
    expect(sched.send(:parse_cron, iface)).to be_nil
  end
end

RSpec.describe "Runtime::Scheduler dispatch without metrics" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "fires the cron without crashing when @metrics is nil" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface cron daily
       schedule "* * * * *"
       no shutdown
      exit
      interface docker img
       image x
      exit
      process p
       block a
        interface docker img
       exit
      exit
      route interface daily process p
      exit
    PRC
    store.commit(doc)
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      logger: Prouterd::NullLogger.new
      # NO metrics
    )
    iface = doc.interfaces.find { |i| i.name == "daily" }
    expect { sched.send(:dispatch, iface, doc, Time.now.utc) }.not_to raise_error
  end
end

RSpec.describe "Runtime::Scheduler.run class-level convenience" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "constructs and immediately calls .run on the instance" do
    allow_any_instance_of(Prouterd::Runtime::Scheduler).to receive(:run)
    Prouterd::Runtime::Scheduler.run(
      store: store,
      runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db)
    )
  end
end

RSpec.describe "Runtime::Scheduler dispatch increments metrics when configured" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "increments :cron_fires_total per dispatch when @metrics is set" do
    doc = parse(<<~PRC)
      router demo
      exit
      interface cron daily
       schedule "* * * * *"
       no shutdown
      exit
      interface docker img
       image x
      exit
      process p
       block hello
        interface docker img
       exit
      exit
      route interface daily process p
      exit
    PRC
    store.commit(doc)
    in_flight = Prouterd::Runtime::InFlightRegistry.new
    metrics = Prouterd::API::Metrics.new(in_flight: in_flight)
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      logger: Prouterd::NullLogger.new,
      metrics: metrics
    )
    iface = doc.interfaces.find { |i| i.name == "daily" }
    expect(metrics).to receive(:increment).with(:cron_fires_total, hash_including(interface: "daily")).at_least(:once)
    sched.send(:dispatch, iface, doc, Time.now.utc)
  end
end

RSpec.describe "Runtime::Scheduler parse_cron with fugit unavailable" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
  after { db.close }

  it "returns nil + logs once when fugit_available? is false" do
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new, jobs: jobs,
      logger: Prouterd::NullLogger.new
    )
    allow(Prouterd::Runtime::Scheduler).to receive(:fugit_available?).and_return(false)
    iface = double(name: "i", type_fields: { "schedule" => "0 * * * *", "timezone" => nil })
    expect(sched.send(:parse_cron, iface)).to be_nil
    expect(sched.send(:parse_cron, iface)).to be_nil # second call skips re-warn
  end
end

RSpec.describe "Runtime::Scheduler parse_cron @fugit_warned re-warn skip" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  after { db.close }

  it "warns once and stays silent on subsequent calls when fugit is missing" do
    sched = Prouterd::Runtime::Scheduler.new(
      store: store, runner: Prouterd::Runner::StubRunner.new,
      jobs: Prouterd::Storage::Repositories::Jobs.new(db),
      logger: Prouterd::NullLogger.new
    )
    allow(Prouterd::Runtime::Scheduler).to receive(:fugit_available?).and_return(false)
    logger = double
    sched.instance_variable_set(:@logger, logger)
    # First call: warns once.
    expect(logger).to receive(:warn).once
    iface = double(name: "i", type_fields: { "schedule" => "0 * * * *", "timezone" => nil })
    sched.send(:parse_cron, iface)
    # Second call: must not re-warn.
    sched.send(:parse_cron, iface)
  end
end
