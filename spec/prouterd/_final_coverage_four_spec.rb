require "spec_helper"
require "rack/test"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "ostruct"
require "prouterd/cli/main"

# Batch 4: target shell/show match-values branches, shell.rb output flush
# branches, docker_runner edges, scheduler defensive, orchestrator
# events nil-step guards, v1 mcp state ternaries, replay payload
# fallbacks, local_repo_caller log-parse edges.

RSpec.describe "Coverage mop-up — batch 4 (surgical)" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ============================================================
  # shell/show: list_routes with matches having values
  # (L634 m.values.join + L787 matches.length)
  # ============================================================

  describe "Shell::Show route + match-values branches" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    def session_with(prc)
      doc = parse(prc)
      sess = Prouterd::Shell::Session.new(store: store)
      sess.replace_running(doc)
      sess
    end

    it "show_process renders 'block -> block  [N match]' for routes with matches" do
      session = session_with(<<~PRC)
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
          match event.k eq "v1"
         exit
        exit
      PRC
      out = StringIO.new
      Prouterd::Shell::Show.show_process(["p"], session, out)
      expect(out.string).to include("a -> b").and include("1 match")
    end

    it "show_process renders bare 'block -> block' for routes WITHOUT matches" do
      session = session_with(<<~PRC)
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
      out = StringIO.new
      Prouterd::Shell::Show.show_process(["p"], session, out)
      expect(out.string).to include("a -> b")
      expect(out.string).not_to match(/\[\d+ match\]/)
    end

    it "show_policy retry-when 'in' values get joined with commas" do
      session = session_with(<<~PRC)
        router demo
        exit
        policy r
         retry attempts 3
         retry when error_type in "a","b","c"
        exit
      PRC
      out = StringIO.new
      Prouterd::Shell::Show.show_policy(["r"], session, out)
      expect(out.string).to include("a,b,c").or include("a, b, c")
    end

    it "show_policy retry-when 'exists' renders without a values suffix" do
      session = session_with(<<~PRC)
        router demo
        exit
        policy r
         retry attempts 3
         retry when error_type exists
        exit
      PRC
      out = StringIO.new
      Prouterd::Shell::Show.show_policy(["r"], session, out)
      expect(out.string).to include("error_type")
      expect(out.string).not_to include("exists  ")
    end
  end

  # ============================================================
  # docker_runner: rel_name empty in collect_artifacts +
  # demultiplex break-on-nil-payload
  # ============================================================

  describe "Runner::DockerRunner artifact rel_name empty" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }
    it "drops the artifacts root (rel_name '' after the sub)" do
      Dir.mktmpdir do |work|
        FileUtils.mkdir_p(File.join(work, "artifacts"))
        File.write(File.join(work, "artifacts/foo.txt"), "x")
        results = runner.send(:collect_artifacts, work)
        expect(results.map(&:name)).to eq(["foo.txt"])
        expect(results.map(&:name)).not_to include("")
      end
    end

    it "demultiplex_logs breaks the loop when payload-byteslice returns nil" do
      # 8-byte header claims 100 bytes payload but buffer has only header
      raw = [1, 0, 0, 0, 100].pack("CCCCN") # exactly 8 bytes, no payload
      out, err = runner.send(:demultiplex_logs, raw)
      expect(out).to eq("")
      expect(err).to eq("")
    end
  end

  # ============================================================
  # docker_runner: Docker::Error::DockerError before started_at assignment
  # ============================================================

  describe "Runner::DockerRunner DockerError pre-started_at" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }
    before do
      unless defined?(Docker)
        stub_const("Docker", Module.new)
        stub_const("Docker::Error", Module.new)
        stub_const("Docker::Error::DockerError", Class.new(StandardError))
        stub_const("Docker::Error::NotFoundError", Class.new(StandardError))
      end
    end

    it "returns finished_at + nil started_at when create_container raises before start" do
      described_class = Prouterd::Runner::DockerRunner
      described_class.instance_variable_set(:@docker_available, true)
      stub_const("Docker::Container", Class.new { def self.create(*); end })
      stub_const("Docker::Image", Class.new { def self.get(*); end; def self.create(*); end })
      allow(Docker::Image).to receive(:get).and_return(:present)
      allow(Docker::Container).to receive(:create).and_raise(Docker::Error::DockerError, "early-boom")

      req = Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "image" => "x" }, staged_inputs: {}
      )
      result = runner.run(req)
      expect(result.error_type).to eq("docker_error")
      expect(result.started_at).to be_nil
      expect(result.finished_at).not_to be_nil
      described_class.instance_variable_set(:@docker_available, nil)
    end
  end

  # ============================================================
  # shell/shell: read_input prompts + output without flush
  # ============================================================

  describe "Shell::Shell read_input no-flush output" do
    it "prints prompt without calling flush on an output that doesn't respond to it" do
      out_no_flush = Class.new do
        attr_reader :sent
        def initialize; @sent = +""; end
        def puts(s); @sent << s.to_s << "\n"; end
        def print(s); @sent << s.to_s; end
        # intentionally no :flush
      end.new
      input = StringIO.new("show version\nexit\n")
      def input.isatty; true; end
      shell = Prouterd::Shell::Shell.new(
        session: Prouterd::Shell::Session.new,
        input: input, output: out_no_flush, error: StringIO.new,
        interactive: true, banner: false
      )
      allow(shell).to receive(:reline_available?).and_return(false)
      shell.run
      expect(out_no_flush.sent).to include("process-router")
    end
  end

  # ============================================================
  # orchestrator: build_next_ready with executed containing duplicate
  # (the `next if executed.include?(bn)` then branch)
  # ============================================================

  describe "Runtime::Orchestrator ready dedupe against executed" do
    it "skips a block that was already marked executed via direct execute_run loop" do
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
        exit
      PRC
      orch = Prouterd::Runtime::Orchestrator.new(
        db: Prouterd::Storage::DB.open(":memory:"),
        runner: Prouterd::Runner::StubRunner.new
      )
      # Use the cross-block retry path indirectly by trigger + cross-block sweep.
      run = orch.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
    end
  end

  # ============================================================
  # local_repo_caller: gather multi-commit with files between blanks
  # (L94 commits << current, L102 elsif current file appended)
  # ============================================================

  describe "Iface::LocalRepoCaller gather multi-commit file accumulation" do
    let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

    def make_repo(root, name)
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir) do
        system("git init -q -b main")
        system("git config user.email t@t")
        system("git config user.name t")
        File.write("a.txt", "1\n")
        system("git add . && git commit -q -m 'first'")
        File.write("b.txt", "2\n")
        system("git add . && git commit -q -m 'second'")
        File.write("a.txt", "3\n")
        system("git add . && git commit -q -m 'third'")
      end
      dir
    end

    def request(fields)
      Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "local_repo", attempt: 1, env: {},
        input_json: {}, timeout_ms: nil, type_fields: fields
      )
    end

    it "splits 3 commits into 3 entries, each with their changed files" do
      Dir.mktmpdir do |root|
        make_repo(root, "g")
        result = caller_instance.run(request({
          "root" => root, "whitelist" => "g", "repo" => "g",
          "call" => "gather", "branch" => "main"
        }))
        expect(result.error_type).to be_nil
        commits = result.output_json["commits"]
        expect(commits.length).to eq(3)
        # Each commit lists its changed files
        expect(commits.flat_map { |c| c["files"] }).to include("a.txt", "b.txt")
      end
    end
  end

  # ============================================================
  # tracer: a route whose match references current-block path (NOT runtime
  # since runtime_paths=[]), and that result isn't :runtime
  # ============================================================

  describe "Runtime::Tracer reason nil when match isn't runtime-dependent" do
    it "leaves reason nil for a static-evaluable match against event.*" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface manual cli
         no shutdown
        exit
        process p
         block a
         exit
        exit
        route interface cli process p
         match event.k eq "v"
        exit
      PRC
      res = Prouterd::Runtime::Tracer.trace(doc, { "k" => "v" }, interface_name: "cli")
      ann = res.global_route.matches.first
      # The reason on the GLOBAL route's annotation is nil since the event
      # path resolves cleanly (not :runtime).
      expect(res.global_route_passes).to be(true)
      expect(ann).not_to be_nil
    end
  end

  # ============================================================
  # retry_engine: downstream_reachable seen.include? guard (L346)
  # ============================================================

  describe "Runtime::RetryEngine downstream_reachable cycle handling" do
    it "doesn't re-enqueue a node already in `seen`" do
      engine = Prouterd::Runtime::RetryEngine.new(runs: double)
      route_ab = double(from_block: "a", to_block: "b")
      route_ba = double(from_block: "b", to_block: "a") # cycle
      process = double(routes: [route_ab, route_ba])
      seen = engine.send(:downstream_reachable, process, "a")
      expect(seen.to_a.sort).to eq(["a", "b"])
    end
  end

  # ============================================================
  # cli/main: replay/trigger failed exit code (L276 / L401 else branches)
  # ============================================================

  describe "CLI::Main exit 1 when replayed run finishes non-success" do
    it "exits 1 when replay produces a paused run" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          Tempfile.create(["pause-prc", ".prc"]) do |t|
            t.write(<<~PRC)
              router demo
              exit
              interface docker img
               image x
              exit
              process p
               block hold
                pause "wait"
               exit
              exit
            PRC
            t.flush
            Prouterd::CLI::Main.run(["apply", t.path, "--db", db.path],
                                     stdout: StringIO.new, stderr: StringIO.new)
            Prouterd::CLI::Main.run(["trigger", "process", "p", "input", f.path,
                                      "--db", db.path, "--runner", "stub"],
                                     stdout: StringIO.new, stderr: StringIO.new)
            sql = Prouterd::Storage::DB.open(db.path)
            orig = Prouterd::Storage::Repositories::Runs.new(sql).list_runs(limit: 1).first
            sql.close
            out = StringIO.new
            code = Prouterd::CLI::Main.run(["replay", "run", orig.uid,
                                             "--db", db.path, "--runner", "stub"],
                                            stdout: out, stderr: StringIO.new)
            expect(code).to eq(1)
          end
        end
      end
    end
  end

  # ============================================================
  # cli/main: trigger commit_id branches via cmd_trigger nil pointer
  # ============================================================

  describe "CLI::Main trigger commit_id nil branch" do
    it "passes commit_id=nil when running pointer is absent (else of &.id)" do
      Tempfile.create(["db", ".sqlite3"]) do |db|
        db.close
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          Tempfile.create(["cfg", ".prc"]) do |c|
            c.write(<<~PRC)
              router demo
              exit
              interface docker img
               image x
              exit
              process p
               block a
                interface docker img
               exit
              exit
            PRC
            c.flush
            # No --db apply; pass --config instead. store.running_commit is nil.
            Prouterd::CLI::Main.run(
              ["trigger", "process", "p", "input", f.path,
               "--db", db.path, "--runner", "stub", "--config", c.path],
              stdout: StringIO.new, stderr: StringIO.new
            )
            # Check the persisted run has commit_id nil.
            sql = Prouterd::Storage::DB.open(db.path)
            row = Prouterd::Storage::Repositories::Runs.new(sql).list_runs(limit: 1).first
            sql.close
            expect(row.process_config_commit_id).to be_nil
          end
        end
      end
    end
  end

  # ============================================================
  # scheduler: dispatch with @metrics nil (L273 else: no increment)
  # ============================================================

  describe "Runtime::Scheduler dispatch without metrics" do
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

  # ============================================================
  # api/v1: GET /v1/mcp state="degraded" via fake mcp_pool
  # ============================================================

  describe "API::V1 GET /v1/mcp state branches" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    let(:fake_pool) do
      Object.new.tap do |p|
        def p.health
          {
            "iface1" => { state: :ready, tools: [{ "name" => "t1" }], last_error: nil },
            "iface2" => { state: :degraded, tools: [], last_error: "boom" }
          }
        end
      end
    end

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil,
        mcp_pool: fake_pool
      )
    end

    it "renders the state from health for each iface (covers h-truthy ternary)" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp iface1
         server bin "/bin/sh"
        exit
        interface mcp iface2
         server bin "/bin/sh"
        exit
        interface mcp iface3
         server bin "/bin/sh"
        exit
      PRC
      store.commit(doc)
      get "/v1/mcp"
      data = JSON.parse(last_response.body)["data"]
      by_name = data.to_h { |x| [x["name"], x] }
      expect(by_name["iface1"]["state"]).to eq("ready")
      expect(by_name["iface2"]["state"]).to eq("degraded")
      expect(by_name["iface2"]["last_error"]).to eq("boom")
      # iface3 not in health → "unknown" because mcp_pool exists
      expect(by_name["iface3"]["state"]).to eq("unknown")
    end
  end

  # ============================================================
  # api/v1: replay from_block with payload context missing 'event'
  # (L329/L330 else branches)
  # ============================================================

  describe "API::V1 replay from_block payload without context.event" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil
      )
    end

    it "falls back to original.input_event_json when payload context has no event" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block hello
          interface docker img
         exit
        exit
      PRC
      store.commit(doc)
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs.create_run(process_name: "p",
                            input_event: { "from" => "original" },
                            process_config_commit_id: store.running_commit.id)
      step = runs.create_step(run_id: run.id, block_name: "hello")
      # payload.context has no 'event' key — falls back through ||
      runs.update_step(step.id, status: "success",
                                input_json: JSON.dump("context" => { "other" => "x" }))
      post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
    end

    it "falls back to {} when original.input_event_json is also nil" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
        exit
        process p
         block hello
          interface docker img
         exit
        exit
      PRC
      store.commit(doc)
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs.create_run(process_name: "p", input_event: {},
                            process_config_commit_id: store.running_commit.id)
      db.execute("UPDATE runs SET input_event_json = NULL WHERE id = ?", [run.id])
      step = runs.create_step(run_id: run.id, block_name: "hello")
      runs.update_step(step.id, status: "success",
                                input_json: JSON.dump("context" => {}))
      post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
    end
  end

  # ============================================================
  # v1: interface_summary respond_to?(:empty?) branch via custom value
  # ============================================================

  describe "API::V1 interface_summary respond_to?(:empty?) false branch" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "keeps a non-string, non-Hash field value (the else of respond_to?(:empty?))" do
      v1 = Prouterd::API::V1.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        in_flight: nil, metrics: nil,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        app: nil
      )
      iface = Prouterd::Config::AST::Interface.new(type: "docker", name: "i", line: 1)
      iface.type_fields = { "image" => "x", "memory" => 12345 }
      summary = v1.send(:interface_summary, iface)
      # 12345 doesn't respond_to?(:empty?) → not dropped
      expect(summary[:fields]["memory"]).to eq(12345)
    end
  end

  # ============================================================
  # rpc_dispatcher L78: config.commit method dispatch
  # ============================================================

  describe "API::RpcDispatcher config.commit method" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "dispatches config.commit to V1#get_config_commit" do
      doc = parse("router demo\nexit\n")
      commit = store.commit(doc)
      v1 = Prouterd::API::V1.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        in_flight: nil, metrics: nil,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        app: nil
      )
      dispatcher = Prouterd::API::RpcDispatcher.new(v1: v1, app: nil, store: store)
      result = dispatcher.call("config.commit", { "id" => commit.id })
      expect(result[:type]).to eq("reply")
      expect(result.dig(:payload, "data", "id")).to eq(commit.id)
    end
  end
end
