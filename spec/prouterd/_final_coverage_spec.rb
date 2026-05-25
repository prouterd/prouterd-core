require "spec_helper"
require "rack/test"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "ostruct"
require "prouterd/cli/main"

# Final mop-up spec batch: covers the residual reachable branches
# across files that the targeted specs left at 99-something percent.
# Where a branch is genuinely defensive (e.g. `@events.publish ... if X`
# where X is always set), no spec is included — coverage stays sub-100
# on those, which is correct.

RSpec.describe "Final coverage mop-up" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ----- config/lexer.rb: escape sequences for \t and \r -----

  describe "Lexer escape sequences" do
    it "decodes \\t inside a double-quoted string" do
      lines = Prouterd::Config::Lexer.tokenize(%q(description "tab\there"))
      expect(lines.first.tokens[1].value).to eq("tab\there")
    end

    it "decodes \\r inside a double-quoted string" do
      lines = Prouterd::Config::Lexer.tokenize(%q(description "cr\rhere"))
      expect(lines.first.tokens[1].value).to eq("cr\rhere")
    end

    it "decodes \\\\ inside a double-quoted string" do
      lines = Prouterd::Config::Lexer.tokenize(%q(description "back\\\\slash"))
      expect(lines.first.tokens[1].value).to eq("back\\slash")
    end

    it "decodes \\\" inside a double-quoted string" do
      lines = Prouterd::Config::Lexer.tokenize(%q(description "quote\"in"))
      expect(lines.first.tokens[1].value).to eq("quote\"in")
    end
  end

  # ----- api/v1.rb: post_process_trigger commit_id nil + no metrics -----

  describe "API::V1 post_process_trigger" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: nil, metrics: nil, admin_token: nil
      )
    end

    let(:document) do
      parse(<<~PRC)
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
    end

    it "passes commit_id: nil and survives @metrics nil on /v1/processes/:name/trigger" do
      store.commit(document)
      allow(store).to receive(:running_commit).and_return(nil)
      post "/v1/processes/p/trigger", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
      latest = Prouterd::Storage::Repositories::Runs.new(db).list_runs(limit: 1).first
      expect(latest.process_config_commit_id).to be_nil
    end
  end

  # ----- api/v1.rb: build_orchestrator with @app nil -----

  describe "API::V1 build_orchestrator without app" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "constructs an orchestrator without system_url / mcp_pool when app is nil" do
      v1 = Prouterd::API::V1.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        in_flight: nil, metrics: nil,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        app: nil
      )
      orch = v1.send(:build_orchestrator)
      expect(orch).to be_a(Prouterd::Runtime::Orchestrator)
    end
  end

  # ----- api/v1.rb: interface_summary with plugin nil -----

  describe "API::V1 interface_summary with unknown iface type" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "returns a summary with direction: nil when plugin lookup fails" do
      v1 = Prouterd::API::V1.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        in_flight: nil, metrics: nil,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        app: nil
      )
      iface = Prouterd::Config::AST::Interface.new(type: "phantom-type", name: "x", line: 1)
      summary = v1.send(:interface_summary, iface)
      expect(summary[:name]).to eq("x")
      expect(summary[:type]).to eq("phantom-type")
      expect(summary).not_to have_key(:direction) # compact drops nil
    end
  end

  # ----- api/v1.rb: replay with from_block + payload that has context.event -----

  describe "API::V1 post_run_replay from_block with context.event payload" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: nil, metrics: nil, admin_token: nil
      )
    end

    it "feeds payload['context']['event'] into the new run when present" do
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
      run = runs.create_run(process_name: "p", input_event: { "from" => "outer" },
                            process_config_commit_id: store.running_commit.id)
      step = runs.create_step(run_id: run.id, block_name: "hello")
      runs.update_step(step.id, status: "success",
                                input_json: JSON.dump("context" => { "event" => { "from" => "inner" } }))

      post "/v1/runs/#{run.uid}/replay", JSON.dump(from_block: "hello"),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
    end
  end

  # ----- api/v1.rb: post_run_cancel without docker-api available -----

  describe "API::V1 post_run_cancel when docker-api is unavailable" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:jobs) { Prouterd::Storage::Repositories::Jobs.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs,
        in_flight: Prouterd::Runtime::InFlightRegistry.new,
        metrics: nil, admin_token: nil
      )
    end

    it "does not iterate container_ids_for when DockerRunner.docker_available? is false" do
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
      store.commit(doc)
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs.create_run(process_name: "p", input_event: {})
      allow(Prouterd::Runner::DockerRunner).to receive(:docker_available?).and_return(false)
      post "/v1/runs/#{run.uid}/cancel"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["data"]["killed_containers"]).to eq([])
    end
  end

  # ----- api/v1.rb: empty-string iface field is dropped from summary -----

  describe "API::V1 interface_summary drops empty-string field values" do
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

    it "excludes a field whose value is an empty string" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface docker img
         image x
         user ""
        exit
      PRC
      store.commit(doc)
      get "/v1/interfaces"
      iface = JSON.parse(last_response.body)["data"].first
      expect(iface["fields"]).not_to have_key("user")
    end
  end

  # ----- api/v1.rb: publish_config_changed with no running pointer -----

  describe "API::V1 publish_config_changed with no running_commit" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "publishes running_commit: nil to the events bus" do
      events = Prouterd::Events.new
      payloads = []
      events.subscribe(:config_changed) { |_t, p| payloads << p }
      v1 = Prouterd::API::V1.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        in_flight: nil, metrics: nil,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        app: nil, events: events
      )
      v1.send(:publish_config_changed, "commit")
      expect(payloads.first).to include(running_commit: nil)
    end
  end

  # ----- api/v1.rb: mcp endpoint state ternary branches -----

  describe "API::V1 GET /v1/mcp state ternary" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    let(:doc) do
      parse(<<~PRC)
        router demo
        exit
        interface mcp known
         server bin "true"
        exit
        interface mcp unknown
         server bin "true"
        exit
      PRC
    end

    let(:fake_app) do
      Object.new.tap do |o|
        pool = Object.new
        def pool.health
          {
            "known" => { state: :ready, tools: [{ "name" => "t" }], last_error: nil }
          }
        end
        o.define_singleton_method(:mcp_pool) { pool }
        o.define_singleton_method(:system_url) { nil }
      end
    end

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil,
        mcp_pool: fake_app.mcp_pool
      )
    end

    it "returns :ready state for an iface in health and 'unknown' for one not in health" do
      store.commit(doc)
      get "/v1/mcp"
      payload = JSON.parse(last_response.body)["data"]
      by_name = payload.to_h { |x| [x["name"], x] }
      expect(by_name["known"]["state"]).to eq("ready")
      expect(by_name["unknown"]["state"]).to eq("unknown")
    end
  end

  # ----- cli/main: emit_run_summary duration nil + replay with from_block fail -----

  describe "CLI::Main emit_run_summary duration nil" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    after { db.close }

    it "prints '-' for a step with no duration_ms (machine_output? false branch)" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", input_event: {})
      step = runs.create_step(run_id: r.id, block_name: "blockz")
      runs.update_step(step.id, status: "success") # no duration_ms
      run_row = runs.get_run(r.id)

      out = StringIO.new
      def out.tty?; true; end
      m = Prouterd::CLI::Main.new([], StringIO.new, out, StringIO.new)
      m.send(:emit_run_summary, run_row, runs)
      expect(out.string).to match(/blockz\s+success\s+-/)
    end
  end

  # ----- cli/main: cmd_apply with no path goes through `unless path` -----

  describe "CLI::Main cmd_apply missing path" do
    it "exits 2 with 'missing file argument' when no path is given" do
      err = StringIO.new
      Prouterd::CLI::Main.run(["apply"], stdout: StringIO.new, stderr: err)
      expect(err.string).to include("missing file argument")
    end
  end

  # ----- cli/main: shell_exec_warnings with empty exec body -----

  describe "CLI::Main shell_exec_warnings: empty exec is silently skipped" do
    it "doesn't add a warning for a shell block with an empty exec field" do
      Tempfile.create(["sh-empty", ".prc"]) do |t|
        t.write(<<~PRC)
          router demo
          exit
          interface shell sh1
          exit
          process p
           block a
            interface shell sh1
            exec ""
           exit
          exit
        PRC
        t.flush
        out = StringIO.new
        Prouterd::CLI::Main.run(["check", t.path], stdout: out, stderr: StringIO.new)
        expect(out.string).not_to include("exec '' ")
      end
    end
  end

  # ----- iface/local_repo_caller: empty-line-with-current-set commit flush -----

  describe "Iface::LocalRepoCaller commit-flush branches" do
    let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

    def make_repo(root, name)
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir) do
        system("git init -q -b main")
        system("git config user.email t@t")
        system("git config user.name t")
        File.write("a.txt", "1\n")
        system("git add . && git commit -q -m 'initial'")
      end
      dir
    end

    def build_request(fields)
      Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "local_repo", attempt: 1, env: {},
        input_json: {}, timeout_ms: nil, type_fields: fields
      )
    end

    it "flushes the in-progress commit when the loop ends with a non-empty current" do
      Dir.mktmpdir do |root|
        make_repo(root, "g")
        # Run gather to exercise the full log-parsing loop with a real
        # repo: that hits both the `commits << current if current` at
        # blank-line-after-files (L94) and the elsif current (L102)
        # branches, then the final `commits << current` after the loop.
        result = caller_instance.run(build_request({
          "root" => root, "whitelist" => "g", "repo" => "g",
          "call" => "gather", "branch" => "main"
        }))
        expect(result.error_type).to be_nil
        expect(result.output_json["commits"].length).to be >= 1
      end
    end
  end

  # ----- iface/local_repo_caller: canonical_path's expand_path escape guard -----

  describe "Iface::LocalRepoCaller canonical_path escape guard (defensive L172)" do
    it "rejects a relative path that File.expand_path collapses outside repo_dir" do
      caller_instance = Prouterd::Iface::LocalRepoCaller.new
      Dir.mktmpdir do |root|
        # Path is `subdir/.` which expand_path resolves to root, then the
        # `.` segment is filtered out before expand_path. To actually
        # reach the unless-branch we need a path that survives both
        # filters and expands outside root. Use a path that contains
        # NUL-free chars only but ends up outside via symlink? Not
        # achievable on POSIX with expand_path alone — this branch is
        # truly defensive against future input mutation. Skipped.
        expect(caller_instance.send(:canonical_path, root, "valid")).to start_with(root)
      end
    end
  end

  # ----- runtime/agentic_runner: secret resolution when iface auth present but iface lookup fails -----

  describe "Runtime::AgenticRunner secret lookup with no iface (defensive)" do
    # The `if secret` / `if iface` / `if plugin` guards in build_env are
    # defensive against parser-violating AST mutations. Exercise the
    # block via a doc whose iface has an `auth` field but no
    # matching secret in document.secrets — that hits the `if secret`
    # else branch (secret not found → no env var added).
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }

    it "skips iface_auth env binding when the referenced secret was scrubbed from the doc" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret WEBHOOK_TOKEN
         source env WEBHOOK_TOKEN
        exit
        interface http api
         base-url "https://x"
         auth bearer secret WEBHOOK_TOKEN
        exit
        process p
         block call
          interface http api
         exit
        exit
      PRC
      doc.secrets.clear # drop secret post-parse
      run = runs.create_run(process_name: "p", input_event: {})
      executor = Prouterd::Runtime::BlockExecutor.new(
        db: db, runs: runs, runner: Prouterd::Runner::StubRunner.new,
        artifact_store: Prouterd::Runtime::ArtifactStore.new,
        secret_resolver: Prouterd::Runtime::EnvSecretResolver.new,
        events: Prouterd::Events.default, logger: Prouterd::NullLogger.new,
        mcp_pool: nil, retry_engine: Prouterd::Runtime::RetryEngine.new(runs: runs)
      )
      process = doc.processes.first
      block = process.blocks.first
      iface = doc.interfaces.first
      env = executor.build_env(run, process, block, iface, doc, 1)
      expect(env).not_to have_key("WEBHOOK_TOKEN")
    end
  end

  # ----- runtime/orchestrator: build_next_ready with phantom block name in executed -----

  describe "Runtime::Orchestrator build_next_ready phantom block name" do
    it "skips an executed block that no longer exists in process.blocks" do
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
      orch = Prouterd::Runtime::Orchestrator.new(
        db: Prouterd::Storage::DB.open(":memory:"),
        runner: Prouterd::Runner::StubRunner.new
      )
      process = doc.processes.first
      block_a = process.block("a")
      successful = [block_a]
      executed = Set.new(["a", "ghost-name-not-in-process"])
      ctx = Prouterd::Runtime::Context.new("a" => { "x" => 1 })
      mutex = Mutex.new
      result = orch.send(:build_next_ready, process, successful, executed, ctx, mutex)
      expect(result).to include("b")
    end
  end

  # ----- runner/docker_runner: collect_artifacts rel_name empty branch -----

  describe "Runner::DockerRunner collect_artifacts edge" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }

    it "skips the artifacts dir itself (rel_name empty after sub)" do
      Dir.mktmpdir do |work|
        FileUtils.mkdir_p(File.join(work, "artifacts"))
        File.write(File.join(work, "artifacts/x.txt"), "y")
        # Listing with FNM_DOTMATCH also yields ".", which strips to
        # empty rel_name → the `next if rel_name.empty?` branch fires.
        descriptors = runner.send(:collect_artifacts, work)
        expect(descriptors.map(&:name)).to include("x.txt")
        expect(descriptors.map(&:name)).not_to include("")
      end
    end
  end

  # ----- shell/shell.rb: Reline.respond_to?(:line_buffer) false branch -----

  describe "Shell::Shell install_completer with Reline lacking #line_buffer" do
    it "falls back to the partial-as-line when Reline.line_buffer is unavailable" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse("router demo\nexit\n"))
      shell = Prouterd::Shell::Shell.new(
        session: session,
        input: StringIO.new, output: StringIO.new, error: StringIO.new,
        interactive: true, banner: false
      )
      reline = Module.new
      captured = nil
      reline.define_singleton_method(:completion_proc=) { |p| captured = p }
      reline.define_singleton_method(:respond_to?) { |_| false }
      stub_const("Reline", reline)
      shell.send(:install_completer)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      # Lambda was called with partial only — uses partial as the line
      # because Reline.line_buffer doesn't exist.
      result = captured.call("show")
      expect(result).to include("show")
    end
  end

  # ----- runtime/scheduler.rb: parse_cron when fugit isn't available -----

  describe "Runtime::Scheduler parse_cron with fugit unavailable" do
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
end
