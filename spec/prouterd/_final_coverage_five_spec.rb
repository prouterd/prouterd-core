require "spec_helper"
require "rack/test"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "prouterd/cli/main"

RSpec.describe "Coverage mop-up — batch 5" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ============================================================
  # shell/show.rb L787: process route with no matches inside
  # show_process_routes_table
  # ============================================================

  describe "Shell::Show list_routes process-routes empty-matches branch" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "renders 'a -> b' without [N match] for routes with no match clauses" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
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
      session = Prouterd::Shell::Session.new(store: store)
      session.replace_running(doc)
      out = StringIO.new
      Prouterd::Shell::Show.list_routes([], session, out)
      expect(out.string).to include("a -> b")
      expect(out.string).not_to match(/a -> b\s+\[/)
    end

    it "renders 'a -> b [1 match]' for process routes with matches via list_routes" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block a
          interface docker img
         exit
         block b
          interface docker img
         exit
         route a b
          match event.k eq "v"
         exit
        exit
      PRC
      session = Prouterd::Shell::Session.new(store: store)
      session.replace_running(doc)
      out = StringIO.new
      Prouterd::Shell::Show.list_routes([], session, out)
      expect(out.string).to include("[1 match]")
    end
  end

  # ============================================================
  # cli/main: resume exit 1 path (resume returns non-success run)
  # ============================================================

  describe "CLI::Main resume exit code != success" do
    it "exits 1 when resumed run finishes with non-success status" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        # Build a process where resume of the paused block leads to ANOTHER pause
        Tempfile.create(["double-pause", ".prc"]) do |t|
          t.write(<<~PRC)
            router demo
            exit
            interface docker img
             image x
            exit
            process p
             block ask
              pause "first"
             exit
             block confirm
              pause "second"
             exit
             route ask confirm
            exit
          PRC
          t.flush
          Tempfile.create(["evt", ".json"]) do |f|
            f.write('{}')
            f.flush
            Prouterd::CLI::Main.run(["apply", t.path, "--db", db.path],
                                     stdout: StringIO.new, stderr: StringIO.new)
            Prouterd::CLI::Main.run(["trigger", "process", "p", "input", f.path,
                                      "--db", db.path, "--runner", "stub"],
                                     stdout: StringIO.new, stderr: StringIO.new)
            sql = Prouterd::Storage::DB.open(db.path)
            paused = Prouterd::Storage::Repositories::Runs.new(sql).list_runs(status: "paused", limit: 1).first
            sql.close
            code = Prouterd::CLI::Main.run(["resume", "run", paused.uid, "--db", db.path, "--runner", "stub"],
                                            stdout: StringIO.new, stderr: StringIO.new)
            # After resume, the run hits the second `pause` → still not "success"
            expect(code).to eq(1)
          end
        end
      end
    end
  end

  # ============================================================
  # session L97: replay_from with payload.context.event present
  # ============================================================

  describe "Shell::Session replay_from with payload.context.event" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:session) { Prouterd::Shell::Session.new(store: store, runner: runner) }
    after { db.close }

    it "uses payload.context.event when present (the first branch of ||)" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
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
      store.commit(doc)
      original = session.orchestrator.trigger(doc, "p",
                                               input_event: { "from" => "outer" },
                                               commit_id: store.running_commit.id)
      step = Prouterd::Storage::Repositories::Runs.new(db).list_steps(original.id).find { |s| s.block_name == "b" }
      # context has 'event' key — that one wins.
      db.execute("UPDATE run_steps SET input_json = ? WHERE id = ?",
                 [JSON.dump("context" => { "event" => { "from" => "inner" } }), step.id])
      replayed = session.replay_from(original.uid, "b")
      expect(replayed.status).to eq("success")
    end

    it "falls back to original.input_event_json when payload.context lacks event AND has nil context" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
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
      store.commit(doc)
      original = session.orchestrator.trigger(doc, "p",
                                               input_event: { "from" => "outer" },
                                               commit_id: store.running_commit.id)
      step = Prouterd::Storage::Repositories::Runs.new(db).list_steps(original.id).find { |s| s.block_name == "b" }
      # payload has no 'context' key at all → `payload["context"]&.dig` returns nil → fallback
      db.execute("UPDATE run_steps SET input_json = ? WHERE id = ?",
                 [JSON.dump("other" => "x"), step.id])
      replayed = session.replay_from(original.uid, "b")
      expect(replayed.status).to eq("success")
    end
  end

  # ============================================================
  # shell/shell.rb L133: line.nil? branch from Reline.readline
  # ============================================================

  describe "Shell::Shell read_input Reline returns nil (EOF)" do
    it "returns nil (no '#{?\n}' suffix) when Reline.readline returns nil" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse("router demo\nexit\n"))
      session.mode_stack << Prouterd::Shell::Modes::User.new
      input = StringIO.new
      def input.isatty; true; end
      shell = Prouterd::Shell::Shell.new(
        session: session,
        input: input, output: StringIO.new, error: StringIO.new,
        interactive: true, banner: false
      )
      reline = Module.new
      reline.define_singleton_method(:readline) { |_, _| nil }
      reline.define_singleton_method(:completion_proc=) { |_| }
      reline.define_singleton_method(:respond_to?) { |sym| sym == :completion_proc= }
      stub_const("Reline", reline)
      expect(shell.run).to eq(0)
    end
  end

  # ============================================================
  # docker_runner L296: case stream `else` branch (unknown stream byte
  # within the `case` of capture_logs)
  # ============================================================

  describe "Runner::DockerRunner capture_logs unknown stream symbol" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }
    it "ignores chunks delivered with an unknown stream identifier" do
      fake = Class.new do
        def streaming_logs(**)
          yield :unknown_stream_name, "ignored"
          yield :stdout, "real"
        end
      end.new
      out, err = runner.send(:capture_logs, fake)
      expect(out).to eq("real")
      expect(err).to eq("")
    end
  end

  # ============================================================
  # docker_runner L430: rel_name empty branch in collect_artifacts
  # (force File.lstat to claim the artifacts dir itself is a file via
  # adding a real file path that strips to "")
  # ============================================================
  # Already covered in batch 4; this branch fires only when Dir.glob
  # returns the artifacts root, which doesn't normally happen with
  # FNM_DOTMATCH.

  # ============================================================
  # shell_runner L272: rel.empty? branch in collect_artifacts
  # ============================================================

  describe "Runner::ShellRunner collect_artifacts rel.empty? branch" do
    let(:runner) { Prouterd::Runner::ShellRunner.new }
    it "drops empty-rel entries from the listing" do
      Dir.mktmpdir do |work|
        art_dir = File.join(work, "artifacts")
        FileUtils.mkdir_p(art_dir)
        File.write(File.join(art_dir, "f.txt"), "x")
        # Override Dir.glob to inject the artifacts root itself as a yielded
        # path so the post-sub rel becomes "".
        original = Dir.method(:glob)
        allow(Dir).to receive(:glob) do |pattern, *args|
          paths = original.call(pattern, *args)
          paths.unshift(art_dir) # rel after sub("\A<art_dir>/?", "") is ""
          paths
        end
        result = runner.send(:collect_artifacts, work)
        expect(result.map(&:name)).to eq(["f.txt"])
      end
    end
  end

  # ============================================================
  # api/v1: GET /v1/mcp with @app present but mcp_pool nil — `else: 4`
  # of `health = @app&.mcp_pool&.health || {}` (the `||` else)
  # ============================================================

  describe "API::V1 GET /v1/mcp falls back to {} health when mcp_pool.health is nil" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    let(:nil_health_pool) do
      Object.new.tap do |p|
        def p.health; nil; end
      end
    end

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil,
        mcp_pool: nil_health_pool
      )
    end

    it "treats pool with nil health as empty → state: 'unknown'" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp m
         server bin "/bin/sh"
        exit
      PRC
      store.commit(doc)
      get "/v1/mcp"
      data = JSON.parse(last_response.body)["data"]
      expect(data.first["state"]).to eq("unknown")
    end
  end
end
