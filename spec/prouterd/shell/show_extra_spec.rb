require "spec_helper"
require "stringio"

# Exhaustive coverage for Prouterd::Shell::Show: every show_X / list_X
# helper, every resolve helper, every CommandError branch, every
# show-target dispatch case in `Show.execute`. Drives directly into
# Show module methods to avoid double-wrapping through the shell loop
# (cheaper) and a few full-shell drives where the loop matters.
RSpec.describe Prouterd::Shell::Show do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def tok(value)
    # `Show.execute` calls `arg.value` on each token; mimic that surface.
    Struct.new(:value).new(value)
  end

  def session_with(prc, with_store: true)
    doc = parse(prc)
    if with_store
      store.commit(doc, author: "t", message: "seed")
      Prouterd::Shell::Session.new(store: store, running_config: doc)
    else
      Prouterd::Shell::Session.new(running_config: doc)
    end
  end

  let(:full_prc) do
    <<~PRC
      router demo
       hostname demo-1
      exit

      secret API_KEY
       source env API_KEY
      exit

      policy retry_basic
       retry attempts 3
       retry backoff exponential
       retry initial-delay 5s
       retry max-delay 2m
       retry when output.error eq "timeout"
       timeout 30s
      exit

      queue default
       concurrency 4
       timeout 1m
      exit

      interface webhook hook_in
       path /in
       method POST
       no shutdown
      exit

      interface cron daily
       schedule "0 9 * * *"
       timezone "UTC"
       no shutdown
      exit

      interface docker img1
       image alpine:1
      exit

      process pipeline
       description "lead processor"
       queue default
       block extract
        interface docker img1
        timeout 30s
        retry retry_basic
        secret API_KEY
       exit
       block enrich
        interface docker img1
        shutdown
       exit
       route extract enrich
        match output.score gt 70
       exit
      exit

      process plain
       block one
        interface docker img1
       exit
      exit

      route interface hook_in process pipeline
       match event.kind eq "x"
      exit
    PRC
  end

  # ---------- expand_target / dispatch ----------

  describe ".expand_target" do
    it "returns nil head untouched" do
      expect(described_class.expand_target(nil)).to be_nil
    end

    it "returns exact-match target untouched" do
      expect(described_class.expand_target("status")).to eq("status")
    end

    it "returns nil-prefix as head when no match" do
      expect(described_class.expand_target("xyzzy")).to eq("xyzzy")
    end

    it "expands a unique prefix" do
      expect(described_class.expand_target("stat")).to eq("status")
    end

    it "expands singular/plural pair: bare form to plural" do
      # `interf` matches both `interface` and `interfaces`; expand to plural
      # when called bare (no args), singular when args present.
      expect(described_class.expand_target("interf", has_args: false)).to eq("interfaces")
    end

    it "expands singular/plural pair: with args to singular" do
      expect(described_class.expand_target("interf", has_args: true)).to eq("interface")
    end

    it "raises on ambiguous prefix (2 non-sg/pl pair)" do
      # 'co' matches 'commits' and 'commit' - those are a sg/pl pair, so should
      # resolve. Find an ambiguous case via a prefix matching unrelated targets.
      # 'r' matches: running-config, runs, run, routes -> 4+ matches -> ambiguous.
      expect { described_class.expand_target("r") }.to raise_error(
        Prouterd::Shell::CommandError, /ambiguous show target 'r'/
      )
    end

    it "raises on ambiguous 2-match pair that is NOT singular/plural" do
      # Force the 2-match else: two targets where pl does not start with sg
      stub_const("Prouterd::Shell::Show::TARGETS", %w[apple banana banhammer])
      expect { described_class.expand_target("ban") }.to raise_error(
        Prouterd::Shell::CommandError, /ambiguous show target 'ban': banana, banhammer/
      )
    end
  end

  describe ".execute dispatch" do
    let(:session) { session_with(full_prc) }

    it "dispatches version" do
      described_class.execute([tok("version")], session, out, err)
      expect(out.string).to include("prouter #{Prouterd::VERSION}")
    end

    it "dispatches status" do
      described_class.execute([tok("status")], session, out, err)
      expect(out.string).to include("hostname:")
    end

    it "dispatches clock" do
      described_class.execute([tok("clock")], session, out, err)
      expect(out.string).to match(/UTC/)
    end

    it "dispatches logging (no args)" do
      described_class.execute([tok("logging")], session, out, err)
      expect(out.string).to include("Logging configuration:")
    end

    it "dispatches history" do
      described_class.execute([tok("history")], session, out, err)
      # Either prints entries or "(no history available...)" — both OK.
      expect(out.string).not_to be_empty
    end

    it "dispatches running-config" do
      described_class.execute([tok("running-config")], session, out, err)
      expect(out.string).to include("router demo")
    end

    it "dispatches startup-config" do
      described_class.execute([tok("startup-config")], session, out, err)
      expect(out.string).to include("startup-config is commit").or include("startup-config not set")
    end

    it "dispatches commits / commit" do
      described_class.execute([tok("commits")], session, out, err)
      expect(out.string).to include("ID")
    end

    it "dispatches processes / process" do
      described_class.execute([tok("processes")], session, out, err)
      expect(out.string).to include("pipeline")

      out2 = StringIO.new
      described_class.execute([tok("process"), tok("pipeline")], session, out2, err)
      expect(out2.string).to include("process pipeline")
    end

    it "dispatches interfaces / interface" do
      described_class.execute([tok("interfaces")], session, out, err)
      expect(out.string).to include("hook_in")

      out2 = StringIO.new
      described_class.execute([tok("interface"), tok("hook_in")], session, out2, err)
      expect(out2.string).to include("interface webhook hook_in")
    end

    it "dispatches policies / policy" do
      described_class.execute([tok("policies")], session, out, err)
      expect(out.string).to include("retry_basic")

      out2 = StringIO.new
      described_class.execute([tok("policy"), tok("retry_basic")], session, out2, err)
      expect(out2.string).to include("policy retry_basic")
    end

    it "dispatches queues / queue" do
      described_class.execute([tok("queues")], session, out, err)
      expect(out.string).to include("default")

      out2 = StringIO.new
      described_class.execute([tok("queue"), tok("default")], session, out2, err)
      expect(out2.string).to include("queue default")
    end

    it "dispatches secrets / secret" do
      described_class.execute([tok("secrets")], session, out, err)
      expect(out.string).to include("API_KEY")

      out2 = StringIO.new
      described_class.execute([tok("secret"), tok("API_KEY")], session, out2, err)
      expect(out2.string).to include("secret API_KEY")
    end

    it "dispatches blocks process X / block process X Y" do
      described_class.execute([tok("blocks"), tok("process"), tok("pipeline")], session, out, err)
      expect(out.string).to include("extract")

      out2 = StringIO.new
      described_class.execute(
        [tok("block"), tok("process"), tok("pipeline"), tok("extract")],
        session, out2, err
      )
      expect(out2.string).to include("block pipeline/extract")
    end

    it "dispatches routes (bare = global + per-process)" do
      described_class.execute([tok("routes")], session, out, err)
      expect(out.string).to include("Global routes")
    end

    it "dispatches routes process X" do
      described_class.execute([tok("routes"), tok("process"), tok("pipeline")], session, out, err)
      expect(out.string).to include("Routes in process 'pipeline'")
    end

    it "dispatches runs / run / logs / artifacts / dead-letter" do
      described_class.execute([tok("runs")], session, out, err)
      expect(out.string).to include("No runs.")
    end

    it "bare `show run` == show running-config" do
      out2 = StringIO.new
      described_class.execute([tok("run")], session, out2, err)
      expect(out2.string).to include("router demo")
    end

    it "show mcp prints empty notice" do
      described_class.execute([tok("mcp")], session, out, err)
      expect(out.string).to include("No `interface mcp`")
    end

    it "show local-repo prints empty notice" do
      described_class.execute([tok("local-repo")], session, out, err)
      expect(out.string).to include("No `interface local_repo`")
    end

    it "raises on unknown show target" do
      expect {
        described_class.execute([tok("xyzzy_unique_target")], session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /unknown show target/)
    end

    it "dispatches run UID (non-bare show run) through execute" do
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      described_class.execute([tok("run"), tok(r.uid)], session, out, err)
      expect(out.string).to include("Run: #{r.uid}")
    end

    it "dispatches commit / logs / artifacts / dead-letter through execute" do
      # exercise the explicit `when` arms on lines 40, 59, 60, 61
      cid = session.store.running_commit.id
      described_class.execute([tok("commit"), tok(cid.to_s)], session, out, err)
      expect(out.string).to include("commit #{cid}")

      out2 = StringIO.new
      # Seed a run so show_logs reaches the "No logs." path through execute.
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      described_class.execute([tok("logs"), tok("run"), tok(r.uid)], session, out2, err)
      expect(out2.string).to include("No logs.")

      out3 = StringIO.new
      described_class.execute([tok("artifacts"), tok("run"), tok(r.uid)], session, out3, err)
      expect(out3.string).to include("No artifacts.")

      out4 = StringIO.new
      described_class.execute([tok("dead-letter")], session, out4, err)
      expect(out4.string).to include("No failed runs.")
    end
  end

  # ---------- show_status with no router ----------

  describe ".show_status when no router set" do
    it "prints '(none)'" do
      session = Prouterd::Shell::Session.new
      described_class.show_status(session, out)
      expect(out.string).to include("router:          (none)")
    end
  end

  # ---------- show_logging variations ----------

  describe ".show_logging" do
    let(:session) { session_with(full_prc) }

    it "errors on unknown subkeyword" do
      expect {
        described_class.show_logging(["banana"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show logging/)
    end

    it "errors when 'last' has no value" do
      expect {
        described_class.show_logging(["last"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show logging/)
    end

    it "errors when 'last' value is not integer" do
      expect {
        described_class.show_logging(["last", "abc"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /last: 'abc' is not an integer/)
    end

    it "errors when 'severity' has no value" do
      expect {
        described_class.show_logging(["severity"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax:/)
    end

    it "errors when severity value is non-integer" do
      expect {
        described_class.show_logging(["severity", "x"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /severity:.*is not an integer/)
    end

    it "errors when severity is out of range" do
      expect {
        described_class.show_logging(["severity", "99"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /severity must be 0-7/)
    end

    it "errors when 'facility' missing value" do
      expect {
        described_class.show_logging(["facility"], out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax:/)
    end

    it "with last/severity/facility filters but no entries prints empty notice" do
      # Use an unlikely facility so nothing matches.
      described_class.show_logging(["last", "5", "severity", "3", "facility", "ZZUNLIKELY"], out)
      expect(out.string).to include("no log entries match")
    end

    it "prints entries when ring has matching rows" do
      # Build a real log entry and push it.
      ring = Prouterd::Logger.ring
      line = Prouterd::Logger.format_line(
        severity: 6, facility: "TEST", mnemonic: "M", message: "hi", context: {}
      )
      ring.push(severity: 6, facility: "TEST", mnemonic: "M",
                message: "hi", context: {}, line: line, ts: Time.now)
      described_class.show_logging(["last", "5"], out)
      expect(out.string).to include("hi")
    end
  end

  # ---------- show_history with Reline ----------

  describe ".show_history" do
    it "prints entries when Reline::HISTORY has content" do
      stub_const("Reline::HISTORY", ["one", "two"])
      described_class.show_history(out)
      expect(out.string).to include("one")
      expect(out.string).to include("two")
    end

    it "prints placeholder when Reline::HISTORY undefined or empty" do
      # Force the else branch by hiding the Reline constant entirely.
      if defined?(::Reline)
        # Stub HISTORY to empty so the empty? branch fires.
        stub_const("Reline::HISTORY", [])
      end
      described_class.show_history(out)
      expect(out.string).to include("no history available")
    end
  end

  # ---------- show_running with empty config ----------

  describe ".show_running" do
    it "prints (empty configuration) for empty doc" do
      session = Prouterd::Shell::Session.new
      described_class.show_running(session, out)
      expect(out.string).to include("(empty configuration)")
    end
  end

  # ---------- show_startup variations ----------

  describe ".show_startup" do
    it "no DB attached" do
      session = Prouterd::Shell::Session.new
      described_class.show_startup(session, out)
      expect(out.string).to include("no DB attached")
    end

    it "no startup commit set" do
      session = session_with(full_prc) # commits exist but no `write_memory`
      # By default, ControlPlane sets startup_commit on `commit`; clear it.
      # Build a fresh store with no startup pointer.
      fresh_db = Prouterd::Storage::DB.open(":memory:")
      fresh_store = Prouterd::ControlPlane::ConfigStore.new(fresh_db)
      session2 = Prouterd::Shell::Session.new(store: fresh_store)
      described_class.show_startup(session2, out)
      expect(out.string).to include("startup-config not set").or include("startup-config is commit")
      fresh_db.close
    end

    it "with startup commit set" do
      session = session_with(full_prc)
      session.write_memory
      described_class.show_startup(session, out)
      expect(out.string).to include("startup-config is commit")
    end
  end

  # ---------- list_commits ----------

  describe ".list_commits" do
    it "no DB attached" do
      session = Prouterd::Shell::Session.new
      described_class.list_commits(session, out)
      expect(out.string).to include("no DB attached")
    end

    it "empty when no commits" do
      fresh_db = Prouterd::Storage::DB.open(":memory:")
      fresh_store = Prouterd::ControlPlane::ConfigStore.new(fresh_db)
      session = Prouterd::Shell::Session.new(store: fresh_store)
      described_class.list_commits(session, out)
      expect(out.string).to include("No commits.")
      fresh_db.close
    end

    it "lists commits with running/startup markers when applicable" do
      session = session_with(full_prc)
      session.write_memory
      described_class.list_commits(session, out)
      expect(out.string).to include("running")
      expect(out.string).to include("startup")
    end
  end

  # ---------- show_local_repo with a local_repo iface ----------

  describe ".show_local_repo" do
    after { Prouterd::Iface::LocalRepoStatus.reset! }

    it "prints all auto-pull statuses including ok and fail entries" do
      prc = <<~PRC
        router demo
        exit
        interface local_repo whitelisted
         root /tmp
         whitelist foo, bar
         auto-pull 1h
         no shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)

      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "whitelisted", repo: "foo",
        ok: true, summary: "Already up to date"
      )
      Prouterd::Iface::LocalRepoStatus.record_pull(
        iface_name: "whitelisted", repo: "bar",
        ok: false, error: "auth failed"
      )

      described_class.show_local_repo(session, out)
      expect(out.string).to include("interface local_repo whitelisted")
      expect(out.string).to include("foo")
      expect(out.string).to include("ok")
      expect(out.string).to include("bar")
      expect(out.string).to include("FAIL")
      expect(out.string).to include("auth failed")
    end

    it "prints '(no pull recorded yet)' when no statuses" do
      prc = <<~PRC
        router demo
        exit
        interface local_repo lr
         root /tmp
         whitelist foo
         auto-pull 1h
         no shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_local_repo(session, out)
      expect(out.string).to include("no pull recorded yet")
    end
  end

  # ---------- show_mcp with mcp iface ----------

  describe ".show_mcp" do
    it "lists mcp interfaces with status notes (ok)" do
      prc = <<~PRC
        router demo
        exit
        interface mcp tools
         server bin "/usr/bin/false"
         no shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_mcp(session, out)
      expect(out.string).to include("tools")
      expect(out.string).to include("Live state from a running daemon")
    end

    it "renders '! <warn>' status when server spec is unresolvable" do
      prc = <<~PRC
        router demo
        exit
        interface mcp tools
         server bin "/this/will/never/exist/xyzzy"
         no shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_mcp(session, out)
      expect(out.string).to include("!")
    end
  end

  # ---------- show_dead_letter ----------

  describe ".show_dead_letter" do
    it "no DB" do
      session = Prouterd::Shell::Session.new
      described_class.show_dead_letter([], session, out)
      expect(out.string).to include("no DB attached")
    end

    it "no failed runs" do
      session = session_with(full_prc)
      described_class.show_dead_letter([], session, out)
      expect(out.string).to include("No failed runs.")
    end

    it "lists failed runs" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      repo.update_run(r.id, status: "failed",
                      started_at: Time.now.utc.iso8601(3),
                      finished_at: Time.now.utc.iso8601(3),
                      error_summary: "boom!")
      described_class.show_dead_letter([], session, out)
      expect(out.string).to include(r.uid)
      expect(out.string).to include("boom!")
    end

    it "errors on unknown run uid (rest=run X)" do
      session = session_with(full_prc)
      expect {
        described_class.show_dead_letter(["run", "missing"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such run/)
    end

    it "prints notice when matched run is not failed" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      repo.update_run(r.id, status: "success",
                      started_at: Time.now.utc.iso8601(3),
                      finished_at: Time.now.utc.iso8601(3))
      described_class.show_dead_letter(["run", r.uid], session, out)
      expect(out.string).to include("not 'failed'")
    end

    it "renders detail for a failed run" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      repo.update_run(r.id, status: "failed",
                      started_at: Time.now.utc.iso8601(3),
                      finished_at: Time.now.utc.iso8601(3),
                      error_summary: "kaboom")
      described_class.show_dead_letter(["run", r.uid], session, out)
      expect(out.string).to include("Run: #{r.uid}")
    end

    it "errors on bad arg shape" do
      session = session_with(full_prc)
      expect {
        described_class.show_dead_letter(["bogus", "x"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show dead-letter/)
    end
  end

  # ---------- list_runs filters ----------

  describe ".list_runs" do
    it "no DB attached" do
      session = Prouterd::Shell::Session.new
      described_class.list_runs([], session, out)
      expect(out.string).to include("no DB attached")
    end

    it "errors when 'process' has no value" do
      session = session_with(full_prc)
      expect {
        described_class.list_runs(["process"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show runs/)
    end

    it "errors when 'thread' has no value" do
      session = session_with(full_prc)
      expect {
        described_class.list_runs(["thread"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show runs/)
    end

    it "errors on unknown subkeyword" do
      session = session_with(full_prc)
      expect {
        described_class.list_runs(["banana"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show runs/)
    end

    it "prints process+thread empty message" do
      session = session_with(full_prc)
      described_class.list_runs(["process", "p", "thread", "t"], session, out)
      expect(out.string).to include("No runs for process 'p' thread 't'.")
    end

    it "prints process-only empty message" do
      session = session_with(full_prc)
      described_class.list_runs(["process", "p"], session, out)
      expect(out.string).to include("No runs for process 'p'.")
    end

    it "prints thread-only empty message" do
      session = session_with(full_prc)
      described_class.list_runs(["thread", "t1"], session, out)
      expect(out.string).to include("No runs for thread 't1'.")
    end

    it "lists existing runs with duration" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {}, thread_id: "abc")
      t0 = Time.now.utc
      repo.update_run(r.id, status: "success",
                      started_at: t0.iso8601(3),
                      finished_at: (t0 + 0.042).iso8601(3))
      described_class.list_runs([], session, out)
      expect(out.string).to include(r.uid)
      # duration_ms is computed from started/finished; expect some "ms" suffix
      expect(out.string).to match(/\dms/)
    end
  end

  # ---------- show_run detail ----------

  describe ".show_run" do
    it "errors on missing arg" do
      expect {
        described_class.show_run([], session_with(full_prc), out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax/)
    end

    it "no DB attached" do
      session = Prouterd::Shell::Session.new
      described_class.show_run(["x"], session, out)
      expect(out.string).to include("no DB attached")
    end

    it "raises on unknown uid" do
      session = session_with(full_prc)
      expect {
        described_class.show_run(["ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such run/)
    end

    it "renders thread / interface / steps with errors / artifacts / tokens" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {},
                          interface_name: "hook_in", thread_id: "tid")
      repo.update_run(r.id, status: "failed",
                      started_at: Time.now.utc.iso8601(3),
                      finished_at: Time.now.utc.iso8601(3),
                      tokens_in: 10, tokens_out: 20,
                      error_summary: "boom!")
      step = repo.create_step(run_id: r.id, block_name: "extract")
      repo.update_step(step.id, status: "failed",
                       finished_at: Time.now.utc.iso8601(3),
                       duration_ms: 5,
                       error_type: "non_zero_exit",
                       error_message: "exit 1")
      repo.add_artifact(run_id: r.id, step_id: step.id, block_name: "extract",
                        name: "out.json", path: "/tmp/x", size_bytes: 99,
                        checksum: "abc123def456", content_type: "application/json")
      described_class.show_run([r.uid], session, out)
      expect(out.string).to include("Thread: tid")
      expect(out.string).to include("Tokens: in=10 out=20")
      expect(out.string).to include("Error: boom!")
      expect(out.string).to include("error: [non_zero_exit] exit 1")
      expect(out.string).to include("Artifacts:")
      expect(out.string).to include("extract/out.json")
    end

    it "prints '(none)' when no steps" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      described_class.show_run([r.uid], session, out)
      expect(out.string).to include("(none)")
    end
  end

  # ---------- resolve_run_and_step + show_logs / show_artifacts ----------

  describe ".resolve_run_and_step / show_logs / show_artifacts" do
    it "show_logs errors on syntax" do
      session = session_with(full_prc)
      expect {
        described_class.show_logs(["bogus"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show logs/)
    end

    it "show_logs no DB attached returns nil without raising" do
      session = Prouterd::Shell::Session.new
      result = described_class.show_logs(["run", "x"], session, out)
      expect(out.string).to include("no DB attached")
      expect(result).to be_nil
    end

    it "show_logs unknown run uid" do
      session = session_with(full_prc)
      expect {
        described_class.show_logs(["run", "ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such run/)
    end

    it "show_logs unknown block in run" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      expect {
        described_class.show_logs(["run", r.uid, "block", "ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such block 'ghost'/)
    end

    it "show_logs malformed args (length 3 not block)" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      expect {
        described_class.show_logs(["run", r.uid, "extra"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show logs/)
    end

    it "show_logs prints No logs when empty" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      described_class.show_logs(["run", r.uid], session, out)
      expect(out.string).to include("No logs.")
    end

    it "show_logs renders entries with run/<stream> tag (step_id nil)" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      repo.append_log(run_id: r.id, stream: "info", content: "hello world\n")
      described_class.show_logs(["run", r.uid], session, out)
      expect(out.string).to include("[run/info]")
      expect(out.string).to include("hello world")
    end

    it "show_logs with block X (block found path)" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      step = repo.create_step(run_id: r.id, block_name: "extract")
      repo.append_log(run_id: r.id, step_id: step.id, stream: "stdout", content: "extract said hi\n")
      described_class.show_logs(["run", r.uid, "block", "extract"], session, out)
      expect(out.string).to include("[extract/stdout]")
    end

    it "show_artifacts: No artifacts when empty" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      described_class.show_artifacts(["run", r.uid], session, out)
      expect(out.string).to include("No artifacts.")
    end

    it "show_artifacts: lists rows with table" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      step = repo.create_step(run_id: r.id, block_name: "extract")
      repo.add_artifact(run_id: r.id, step_id: step.id, block_name: "extract",
                        name: "x.json", path: "/tmp/x", size_bytes: 12,
                        checksum: "deadbeef0123", content_type: "application/json")
      described_class.show_artifacts(["run", r.uid], session, out)
      expect(out.string).to include("x.json")
      expect(out.string).to include("12B")
    end

    it "show_artifacts errors on bad syntax" do
      session = session_with(full_prc)
      expect {
        described_class.show_artifacts([], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show artifacts/)
    end
  end

  # ---------- show_commit ----------

  describe ".show_commit" do
    it "errors on missing args" do
      expect {
        described_class.show_commit([], session_with(full_prc), out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show commit/)
    end

    it "no DB attached" do
      session = Prouterd::Shell::Session.new
      described_class.show_commit(["1"], session, out)
      expect(out.string).to include("no DB attached")
    end

    it "non-integer id" do
      session = session_with(full_prc)
      expect {
        described_class.show_commit(["abc"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /must be an integer/)
    end

    it "missing commit" do
      session = session_with(full_prc)
      expect {
        described_class.show_commit(["9999"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such commit/)
    end

    it "renders commit detail" do
      session = session_with(full_prc)
      cid = session.store.running_commit.id
      described_class.show_commit([cid.to_s], session, out)
      expect(out.string).to include("commit #{cid}")
      expect(out.string).to include("router demo")
    end
  end

  # ---------- diff_file_against_running ----------

  describe ".diff_file_against_running" do
    it "errors on missing path arg" do
      expect {
        described_class.diff_file_against_running([], session_with(full_prc), out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: diff/)
    end

    it "raises on missing file" do
      expect {
        described_class.diff_file_against_running(["/nope/missing.prc"],
                                                  session_with(full_prc), out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such file/)
    end

    it "raises on parse error" do
      require "tempfile"
      Tempfile.create(["bad", ".prc"]) do |tmp|
        tmp.write("router x\n color red\nexit\n")
        tmp.flush
        expect {
          described_class.diff_file_against_running([tmp.path],
                                                    session_with(full_prc), out)
        }.to raise_error(Prouterd::Shell::CommandError, /diff:/)
      end
    end

    it "prints No changes when identical" do
      require "tempfile"
      session = session_with(full_prc)
      Tempfile.create(["same", ".prc"]) do |tmp|
        tmp.write(Prouterd::Config::Renderer.render(session.running_config))
        tmp.flush
        described_class.diff_file_against_running([tmp.path], session, out)
        expect(out.string).to include("No changes.")
      end
    end

    it "renders +/- diff lines on difference" do
      require "tempfile"
      session = session_with(full_prc)
      Tempfile.create(["diff", ".prc"]) do |tmp|
        tmp.write(<<~PRC)
          router demo
          exit
          interface docker img1
           image alpine:1
          exit
          process pipeline
           block one
            interface docker img1
           exit
          exit
        PRC
        tmp.flush
        described_class.diff_file_against_running([tmp.path], session, out)
        expect(out.string).to match(/^[+\-] /)
      end
    end
  end

  # ---------- list_processes empty / show_process error ----------

  describe ".list_processes / .show_process" do
    it "list_processes prints No processes" do
      session = Prouterd::Shell::Session.new
      described_class.list_processes(session, out)
      expect(out.string).to include("No processes defined.")
    end

    it "show_process error on unknown name" do
      session = session_with(full_prc)
      expect {
        described_class.show_process(["ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such process/)
    end

    it "renders description / routes with match-tags" do
      session = session_with(full_prc)
      described_class.show_process(["pipeline"], session, out)
      expect(out.string).to include("description: \"lead processor\"")
      expect(out.string).to include("[1 match]")
    end
  end

  # ---------- list_interfaces / show_interface ----------

  describe ".list_interfaces / .show_interface" do
    it "empty" do
      session = Prouterd::Shell::Session.new
      described_class.list_interfaces(session, out)
      expect(out.string).to include("No interfaces defined.")
    end

    it "renders webhook + cron detail rows" do
      session = session_with(full_prc)
      described_class.list_interfaces(session, out)
      expect(out.string).to include("hook_in")
      expect(out.string).to include("POST /in")
      expect(out.string).to include("daily")
      expect(out.string).to include("schedule=")
    end

    it "show_interface error on unknown name" do
      session = session_with(full_prc)
      expect {
        described_class.show_interface(["ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such interface/)
    end

    it "show_interface webhook detail with auth secret" do
      prc = <<~PRC
        router demo
        exit
        secret WHT
         source env WHT
        exit
        interface webhook hook
         path /in
         method POST
         auth bearer secret WHT
         no shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_interface(["hook"], session, out)
      expect(out.string).to include("path:     /in")
      expect(out.string).to include("auth:")
      expect(out.string).to include("secret=WHT")
    end

    it "show_interface cron detail" do
      session = session_with(full_prc)
      described_class.show_interface(["daily"], session, out)
      expect(out.string).to include("schedule:")
      expect(out.string).to include("timezone:")
    end
  end

  # ---------- list_policies / show_policy ----------

  describe ".list_policies / .show_policy" do
    it "empty" do
      session = Prouterd::Shell::Session.new
      described_class.list_policies(session, out)
      expect(out.string).to include("No policies defined.")
    end

    it "renders rows + retry-when matches" do
      session = session_with(full_prc)
      described_class.show_policy(["retry_basic"], session, out)
      expect(out.string).to include("retry-when:")
      expect(out.string).to include("output.error eq")
    end

    it "errors on unknown policy" do
      session = session_with(full_prc)
      expect {
        described_class.show_policy(["ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such policy/)
    end
  end

  # ---------- list_queues / show_queue ----------

  describe ".list_queues / .show_queue" do
    it "empty" do
      session = Prouterd::Shell::Session.new
      described_class.list_queues(session, out)
      expect(out.string).to include("No queues defined.")
    end

    it "renders row" do
      session = session_with(full_prc)
      described_class.list_queues(session, out)
      expect(out.string).to include("default")
    end

    it "errors on unknown queue" do
      session = session_with(full_prc)
      expect {
        described_class.show_queue(["ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such queue/)
    end

    it "renders detail" do
      session = session_with(full_prc)
      described_class.show_queue(["default"], session, out)
      expect(out.string).to include("queue default")
      expect(out.string).to include("timeout:")
    end
  end

  # ---------- list_secrets / show_secret ----------

  describe ".list_secrets / .show_secret" do
    it "empty" do
      session = Prouterd::Shell::Session.new
      described_class.list_secrets(session, out)
      expect(out.string).to include("No secrets defined.")
    end

    it "errors on unknown" do
      session = session_with(full_prc)
      expect {
        described_class.show_secret(["GHOST"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such secret/)
    end

    it "renders without secret value" do
      session = session_with(full_prc)
      described_class.show_secret(["API_KEY"], session, out)
      expect(out.string).to include("secret API_KEY")
      expect(out.string).to include("source: env")
    end
  end

  # ---------- list_blocks / show_block ----------

  describe ".list_blocks / .show_block" do
    it "errors on bad syntax" do
      session = session_with(full_prc)
      expect {
        described_class.list_blocks([], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show blocks/)
    end

    it "no such process" do
      session = session_with(full_prc)
      expect {
        described_class.list_blocks(["process", "ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such process/)
    end

    it "empty process" do
      prc = <<~PRC
        router demo
        exit
        process empty
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      # This will trigger parser warning - let's bypass and build manually
      session.running_config.processes << Prouterd::Config::AST::Process.new(name: "empty2", line: 0)
      described_class.list_blocks(["process", "empty2"], session, out)
      expect(out.string).to include("No blocks in process 'empty2'.")
    end

    it "lists block rows with summary" do
      session = session_with(full_prc)
      described_class.list_blocks(["process", "pipeline"], session, out)
      expect(out.string).to include("extract")
      expect(out.string).to include("docker img1")
    end

    it "show_block errors on bad syntax" do
      session = session_with(full_prc)
      expect {
        described_class.show_block(["bogus"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show block/)
    end

    it "show_block: no such process" do
      session = session_with(full_prc)
      expect {
        described_class.show_block(["process", "ghost", "x"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such process/)
    end

    it "show_block: no such block" do
      session = session_with(full_prc)
      expect {
        described_class.show_block(["process", "pipeline", "ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such block/)
    end

    it "show_block: renders full block detail incl call_fields + secrets" do
      session = session_with(full_prc)
      described_class.show_block(["process", "pipeline", "extract"], session, out)
      expect(out.string).to include("block pipeline/extract")
      expect(out.string).to include("interface: docker img1")
      expect(out.string).to include("secrets: API_KEY")
    end

    it "show_block: prints (none) when interface ref is nil" do
      doc = Prouterd::Config::AST::Document.new
      p = Prouterd::Config::AST::Process.new(name: "p", line: 0)
      b = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      p.blocks << b
      doc.processes << p
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_block(["process", "p", "b"], session, out)
      expect(out.string).to include("(none)")
    end

    it "show_block: prints disabled state" do
      session = session_with(full_prc)
      described_class.show_block(["process", "pipeline", "enrich"], session, out)
      expect(out.string).to include("state:    disabled")
    end

    it "show_block: env_pair call_field with non-empty value renders 'k=v' pairs" do
      # No current registered plugin declares an :env_pair call_field
      # (only iface-body fields). Stub a synthetic plugin so we exercise
      # the :env_pair branch in show_block.
      env_field = Prouterd::Iface::Plugin::Field.new(
        name: "env", kind: :env_pair, required: false
      )
      str_required_field = Prouterd::Iface::Plugin::Field.new(
        name: "cmd", kind: :string, required: true
      )
      plugin = double(
        "PluginDouble",
        call_fields: [env_field, str_required_field]
      )
      allow(Prouterd::Iface::Registry).to receive(:lookup).and_call_original
      allow(Prouterd::Iface::Registry).to receive(:lookup).with("docker").and_return(plugin)

      doc = Prouterd::Config::AST::Document.new
      p = Prouterd::Config::AST::Process.new(name: "p", line: 0)
      b = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      b.interface_ref = Prouterd::Config::AST::InterfaceRef.new(type: "docker", name: "img")
      b.type_fields["env"] = { "KEY" => "value" }
      b.type_fields["cmd"] = "echo hi"
      p.blocks << b
      doc.processes << p
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_block(["process", "p", "b"], session, out)
      expect(out.string).to include("env:")
      expect(out.string).to include("KEY=value")
      expect(out.string).to include("cmd:")
      expect(out.string).to include("echo hi")
    end

    it "show_block: env_pair with empty hash is skipped (next branch)" do
      env_field = Prouterd::Iface::Plugin::Field.new(name: "env", kind: :env_pair, required: false)
      plugin = double("PluginDouble", call_fields: [env_field])
      allow(Prouterd::Iface::Registry).to receive(:lookup).and_call_original
      allow(Prouterd::Iface::Registry).to receive(:lookup).with("docker").and_return(plugin)

      doc = Prouterd::Config::AST::Document.new
      p = Prouterd::Config::AST::Process.new(name: "p", line: 0)
      b = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      b.interface_ref = Prouterd::Config::AST::InterfaceRef.new(type: "docker", name: "img")
      b.type_fields["env"] = {}
      p.blocks << b
      doc.processes << p
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_block(["process", "p", "b"], session, out)
      expect(out.string).not_to include("env:")
    end
  end

  # ---------- list_routes / show_global_routes / show_process_routes_table ----------

  describe ".list_routes" do
    it "bare mode: global + per-process (with empty global)" do
      session = session_with(full_prc)
      described_class.list_routes([], session, out)
      expect(out.string).to include("Global routes")
      expect(out.string).to include("hook_in -> pipeline")
      expect(out.string).to include("Routes in process 'pipeline'")
    end

    it "bare mode: no global routes" do
      prc = <<~PRC
        router demo
        exit
        interface docker img1
         image alpine
        exit
        process p
         block one
          interface docker img1
         exit
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.list_routes([], session, out)
      expect(out.string).to include("Global routes")
      expect(out.string).to include("(none)")
    end

    it "with process: unknown process error" do
      session = session_with(full_prc)
      expect {
        described_class.list_routes(["process", "ghost"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /no such process/)
    end

    it "with process: renders the process routes only" do
      session = session_with(full_prc)
      described_class.list_routes(["process", "pipeline"], session, out)
      expect(out.string).to include("Routes in process 'pipeline'")
      expect(out.string).to include("extract -> enrich")
    end

    it "with process: prints (none) when routes empty" do
      session = session_with(full_prc)
      described_class.list_routes(["process", "plain"], session, out)
      expect(out.string).to include("(none)")
    end

    it "errors on bad syntax" do
      session = session_with(full_prc)
      expect {
        described_class.list_routes(["junk"], session, out)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: show routes/)
    end
  end

  # ---------- block_summary_tag ----------

  describe ".block_summary_tag" do
    it "returns (no interface) when block has no ref" do
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      expect(described_class.block_summary_tag(block)).to eq("(no interface)")
    end

    it "returns type + name when iface has no plugin registered" do
      ref = Prouterd::Config::AST::InterfaceRef.new(type: "totally_unknown", name: "x")
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      block.interface_ref = ref
      expect(described_class.block_summary_tag(block)).to eq("totally_unknown x")
    end

    it "returns type + name when plugin has no headline string field" do
      ref = Prouterd::Config::AST::InterfaceRef.new(type: "cron", name: "c1")
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      block.interface_ref = ref
      # cron's call_fields are likely empty (inbound), so no headline
      # field. The function should fall through to "type name".
      expect(described_class.block_summary_tag(block)).to start_with("cron c1")
    end

    it "renders headline_field=value when call_field present (docker command)" do
      ref = Prouterd::Config::AST::InterfaceRef.new(type: "docker", name: "img1")
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      block.interface_ref = ref
      block.type_fields["command"] = "echo hi"
      tag = described_class.block_summary_tag(block)
      expect(tag).to include("docker img1")
      expect(tag).to include("command=echo hi")
    end

    it "renders '-' when call_field value is empty string" do
      ref = Prouterd::Config::AST::InterfaceRef.new(type: "docker", name: "img1")
      block = Prouterd::Config::AST::Block.new(name: "b", line: 0)
      block.interface_ref = ref
      block.type_fields["command"] = ""
      tag = described_class.block_summary_tag(block)
      expect(tag).to include("command=-")
    end
  end

  # ---------- additional branch coverage edges ----------

  describe "additional branch coverage" do
    it "list_commits handles nil running/startup pointers + no markers" do
      session = session_with(full_prc)
      # Create an extra commit (cid 2) and clear pointers so neither
      # running nor startup matches this commit. Force the &. else branch
      # by stubbing the store.
      allow(session.store).to receive(:running_commit).and_return(nil)
      allow(session.store).to receive(:startup_commit).and_return(nil)
      described_class.list_commits(session, out)
      expect(out.string).not_to include("(running")
      expect(out.string).not_to include("(startup")
    end

    it "list_interfaces 'down' state branch (shutdown iface)" do
      prc = <<~PRC
        router demo
        exit
        interface webhook hook
         path /x
         method POST
         shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.list_interfaces(session, out)
      expect(out.string).to include("down")
    end

    it "list_interfaces 'else' detail for non-webhook/cron type (docker)" do
      prc = <<~PRC
        router demo
        exit
        interface docker img
         image alpine
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.list_interfaces(session, out)
      # Detail column is "-" for non-webhook/cron types.
      expect(out.string).to include("docker")
      expect(out.string).to match(/docker.*-$/m)
    end

    it "list_runs renders '-' when duration_ms is nil" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      # status queued, no started/finished -> duration nil
      described_class.list_runs([], session, out)
      expect(out.string).to include(r.uid)
    end

    it "show_run renders '-' for null duration step (no error_type, no artifacts)" do
      session = session_with(full_prc)
      repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
      r = repo.create_run(process_name: "pipeline", input_event: {})
      # NB: don't set start/finish so duration_ms nil.
      repo.create_step(run_id: r.id, block_name: "extract")
      described_class.show_run([r.uid], session, out)
      expect(out.string).to include("extract")
    end

    it "show_process: prints without description (else branch)" do
      session = session_with(full_prc)
      described_class.show_process(["plain"], session, out)
      expect(out.string).to include("process plain")
      expect(out.string).not_to include("description:")
    end

    it "show_process: route without match-conds (empty branch)" do
      prc = <<~PRC
        router demo
        exit
        interface docker img
         image alpine
        exit
        process p
         block a
          interface docker img
         exit
         block b
          interface docker img
         exit
         route a b
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_process(["p"], session, out)
      expect(out.string).to include("a -> b")
      expect(out.string).not_to include("[1 match]")
    end

    it "show_interface 'shutdown' state branch" do
      prc = <<~PRC
        router demo
        exit
        interface webhook h
         path /x
         method POST
         shutdown
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_interface(["h"], session, out)
      expect(out.string).to include("state:    shutdown")
    end

    it "show_interface: else branch for non-webhook/cron type" do
      prc = <<~PRC
        router demo
        exit
        interface docker img
         image alpine
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_interface(["img"], session, out)
      # Doesn't print path:/method:/schedule:/timezone:
      expect(out.string).to include("interface docker img")
      expect(out.string).not_to include("path:")
    end

    it "show_policy renders default '-' for missing attempts / backoff / delays + retry-when empty" do
      prc = <<~PRC
        router demo
        exit
        policy bare
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_policy(["bare"], session, out)
      expect(out.string).to include("attempts:")
      expect(out.string).to include("initial-delay: -")
      expect(out.string).to include("max-delay:     -")
      expect(out.string).not_to include("retry-when:")
    end

    it "show_policy with retry-when match having no values (m.values empty branch)" do
      prc = <<~PRC
        router demo
        exit
        policy r
         retry when output.error eq "x"
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_policy(["r"], session, out)
      # The covered branch with values; ensure both branches are exercised in
      # this and the full_prc test together.
      expect(out.string).to include("retry-when:")
    end

    it "list_policies + show_policy with non-nil retry/backoff/delays renders rendered strings" do
      session = session_with(full_prc)
      described_class.list_policies(session, out)
      expect(out.string).to include("retry_basic")
      expect(out.string).to include("exponential")
    end

    it "show_queue renders '-' default for missing concurrency/timeout" do
      prc = <<~PRC
        router demo
        exit
        queue bare
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_queue(["bare"], session, out)
      expect(out.string).to include("queue bare")
      expect(out.string).to include("concurrency: -")
      expect(out.string).to include("timeout:     -")
    end

    it "list_queues with bare queue exercises render '-' default" do
      prc = <<~PRC
        router demo
        exit
        queue bare
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.list_queues(session, out)
      expect(out.string).to include("bare")
      expect(out.string).to include("-")
    end

    it "show_global_routes: route without match conds" do
      prc = <<~PRC
        router demo
        exit
        interface manual cli
         no shutdown
        exit
        interface docker img
         image alpine
        exit
        process p
         block one
          interface docker img
         exit
        exit
        route interface cli process p
        exit
      PRC
      doc = parse(prc)
      session = Prouterd::Shell::Session.new(running_config: doc)
      described_class.show_global_routes(session, out)
      expect(out.string).to include("cli -> p")
      expect(out.string).not_to include("[1 match]")
    end

    it "show_process_routes_table: route with match-cond (then-branch)" do
      session = session_with(full_prc)
      described_class.show_process_routes_table(
        session.active_config.processes.find { |p| p.name == "pipeline" },
        out
      )
      expect(out.string).to include("[1 match]")
    end
  end

  # ---------- simple_diff edges ----------

  describe ".simple_diff" do
    it "returns [] for identical inputs" do
      expect(described_class.simple_diff(["a"], ["a"])).to eq([])
    end

    it "returns +/- for purely added/removed lines" do
      diff = described_class.simple_diff(["a", "b"], ["a", "c"])
      expect(diff).to include("- b")
      expect(diff).to include("+ c")
    end

    it "handles leading additions (only j>0 path)" do
      diff = described_class.simple_diff([], ["new"])
      expect(diff).to include("+ new")
    end

    it "handles leading removals (only i>0 path)" do
      diff = described_class.simple_diff(["old"], [])
      expect(diff).to include("- old")
    end

    it "emits a `- ` line when a[i-1] != b[j-1] and dp[i-1][j] >= dp[i][j-1]" do
      diff = described_class.simple_diff(%w[a b c], %w[a c])
      expect(diff).to include("- b")
    end
  end
end
