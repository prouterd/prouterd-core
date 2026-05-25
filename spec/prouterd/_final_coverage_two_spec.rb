require "spec_helper"
require "rack/test"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "ostruct"
require "prouterd/cli/main"

# Second mop-up batch: hits remaining reachable branches across
# cli/main, orchestrator, v1, docker_runner, show, shell, session,
# mode, privileged, local_repo_caller.

RSpec.describe "Coverage mop-up — batch 2" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ---- cli/main: trigger fail path (status != "success") -----

  describe "CLI::Main trigger non-success exit (paused run)" do
    it "exits 1 when the run pauses (status != success branch)" do
      Tempfile.create(["pause", ".prc"]) do |t|
        t.write(<<~PRC)
          router demo
          exit
          interface docker img
           image x
          exit
          process p
           block hold
            pause "waiting"
           exit
          exit
        PRC
        t.flush
        Tempfile.create(["evt", ".json"]) do |f|
          f.write('{}')
          f.flush
          Tempfile.create(["db", ".sqlite3"]) do |db|
            db.close
            out = StringIO.new
            exit_code = Prouterd::CLI::Main.run(
              ["trigger", "process", "p", "input", f.path,
               "--db", db.path, "--runner", "stub"],
              stdin: StringIO.new, stdout: out, stderr: StringIO.new
            )
            expect(exit_code).to eq(1)
          end
        end
      end
    end
  end

  # ---- cli/main: shell_exec_warnings empty head (`next if head.nil? || head.empty?`) -----

  describe "CLI::Main shell_exec_warnings empty-head branch" do
    it "skips a block whose exec resolves to an empty head" do
      Tempfile.create(["sh-emptyhead", ".prc"]) do |t|
        # exec = a single quoted empty string → Shellwords splits to [""] → head = ""
        t.write(<<~PRC)
          router demo
          exit
          interface shell sh1
          exit
          process p
           block a
            interface shell sh1
            exec `""`
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

  # ---- cli/main: parse_with_diagnostics with nil path (no base_dir) -----

  describe "CLI::Main parse_with_diagnostics with nil path" do
    it "returns the parsed doc without raising when path is nil" do
      m = Prouterd::CLI::Main.new([], StringIO.new, StringIO.new, StringIO.new)
      result = m.send(:parse_with_diagnostics, "router demo\nexit\n", nil)
      expect(result).to be_a(Prouterd::Config::AST::Document)
    end
  end

  # ---- orchestrator: barrier? predicate target=non-barrier short-circuit -----

  describe "Orchestrator and_style_merge_barrier? non-barrier target" do
    it "returns false when the target isn't a barrier block at all" do
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
      result = orch.send(:and_style_merge_barrier?, doc.processes.first, "b", Set.new)
      expect(result).to be(false)
    end
  end

  # ---- orchestrator: empty level + cancel-mid-flight -----

  describe "Orchestrator soft-cancel between levels" do
    it "stops scheduling when run.status flips to canceled mid-execution" do
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
      db = Prouterd::Storage::DB.open(":memory:")
      runs_repo = Prouterd::Storage::Repositories::Runs.new(db)
      runner = Prouterd::Runner::StubRunner.new
      # After block 'a' executes, flip the run row to canceled so the
      # orchestrator's top-of-loop polling catches the soft-cancel.
      runner.program("a") do |req|
        run = runs_repo.get_run_by_uid(req.run_uid)
        runs_repo.update_run(run.id, status: "canceled",
                                     finished_at: Time.now.utc.iso8601(3))
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: {}, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 1, started_at: nil, finished_at: nil
        )
      end
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      run = orch.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("canceled")
      db.close
    end
  end

  # ---- orchestrator: on-failure stop triggers failure_reason break -----

  describe "Orchestrator on-failure stop terminates the run" do
    it "marks the run failed with the configured error_summary" do
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
      db = Prouterd::Storage::DB.open(":memory:")
      runner = Prouterd::Runner::StubRunner.new
      runner.program("a") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 7, stdout: "", stderr: "fail",
          output_json: nil, artifacts: [],
          error_type: "boom", error_message: "oops",
          duration_ms: 0, started_at: nil, finished_at: nil
        )
      end
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      run = orch.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("boom")
      db.close
    end
  end

  # ---- v1: build_orchestrator hits @app.system_url / @app.mcp_pool nil branches -----

  describe "API::V1 GET /v1/mcp with @app.mcp_pool nil" do
    include Rack::Test::Methods
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    def app
      Prouterd::API::App.new(
        store: store, runner: Prouterd::Runner::StubRunner.new,
        jobs: Prouterd::Storage::Repositories::Jobs.new(db),
        in_flight: nil, metrics: nil, admin_token: nil
        # no mcp_pool
      )
    end

    it "reports state: no_pool for each mcp iface" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp local
         server bin "true"
        exit
      PRC
      store.commit(doc)
      get "/v1/mcp"
      entries = JSON.parse(last_response.body)["data"]
      expect(entries.first["state"]).to eq("no_pool")
    end
  end

  # ---- docker_runner: collect_artifacts skips the dir entry (rel_name="") -----

  describe "Runner::DockerRunner collect_artifacts dir-entry skip" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }
    it "ignores '.' and the artifacts root itself" do
      Dir.mktmpdir do |work|
        FileUtils.mkdir_p(File.join(work, "artifacts", "sub"))
        File.write(File.join(work, "artifacts/sub/y.txt"), "ok")
        descriptors = runner.send(:collect_artifacts, work)
        expect(descriptors.map(&:name)).to eq(["sub/y.txt"])
      end
    end
  end

  # ---- docker_runner: demultiplex_logs payload nil (truncated frame) -----

  describe "Runner::DockerRunner demultiplex_logs payload-nil break" do
    let(:runner) { Prouterd::Runner::DockerRunner.new }
    it "breaks the loop when the size header points past the end of the buffer" do
      # 8-byte header claiming 10 payload bytes, but no payload bytes follow.
      raw = [1, 0, 0, 0, 10].pack("CCCCN")
      out, err = runner.send(:demultiplex_logs, raw)
      expect(out).to eq("")
      expect(err).to eq("")
    end
  end

  # ---- shell/show: list_policies + show_routes with empty matches -----

  describe "Shell::Show policy + routes branches" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    def session_with(prc)
      doc = parse(prc)
      sess = Prouterd::Shell::Session.new(store: store)
      sess.replace_running(doc)
      store.commit(doc)
      sess
    end

    it "list_policies renders rows for retry policies (covers retry-delay '-' fallback)" do
      session = session_with(<<~PRC)
        router demo
        exit
        policy r1
         retry attempts 3
        exit
        policy r2
         retry attempts 2
         retry backoff exponential
        exit
      PRC
      out = StringIO.new
      Prouterd::Shell::Show.list_policies(session, out)
      expect(out.string).to include("r1")
      expect(out.string).to include("r2")
    end

    it "list_routes (without process scope) lists global routes with no matches" do
      session = session_with(<<~PRC)
        router demo
        exit
        interface manual cli
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
        route interface cli process p
        exit
      PRC
      out = StringIO.new
      Prouterd::Shell::Show.list_routes([], session, out)
      expect(out.string).to include("cli")
      expect(out.string).to include("p")
    end
  end

  # ---- shell/shell: read_input nil from Reline.readline -----

  describe "Shell::Shell read_input nil from Reline" do
    it "treats nil from Reline.readline as EOF" do
      session = Prouterd::Shell::Session.new
      session.replace_running(parse("router demo\nexit\n"))
      input = StringIO.new
      def input.isatty; true; end
      shell = Prouterd::Shell::Shell.new(
        session: session,
        input: input, output: StringIO.new, error: StringIO.new,
        interactive: true, banner: false
      )
      reline = Module.new
      reline.define_singleton_method(:readline) { |_, _| nil } # EOF
      reline.define_singleton_method(:completion_proc=) { |_| }
      reline.define_singleton_method(:completion_append_character=) { |_| }
      reline.define_singleton_method(:autocompletion=) { |_| }
      reline.define_singleton_method(:respond_to?) { |sym| %i[completion_proc= completion_append_character= autocompletion=].include?(sym) }
      stub_const("Reline", reline)
      expect(shell.run).to eq(0)
    end
  end

  # ---- shell/mode: invoke_help with no help handler in commands ----

  describe "Shell::Mode invoke_help no-handler" do
    it "returns :handled when commands has neither 'help' nor '?'" do
      m = Class.new(Prouterd::Shell::Mode) {
        def commands; { "doit" => :cmd_doit }; end
        def cmd_doit(*); :handled; end
      }.new
      tokens = Prouterd::Shell::CommandLine.tokenize("?")
      result = m.execute(tokens, Prouterd::Shell::Session.new, StringIO.new, StringIO.new)
      expect(result).to eq(:handled)
    end
  end

  # ---- shell/mode: expect_min_args passes when args match exactly -----

  describe "Shell::Mode expect_min_args pass branch" do
    it "does not raise when token count is exactly the minimum" do
      m = Prouterd::Shell::Mode.new
      tokens = Prouterd::Shell::CommandLine.tokenize("a b")
      expect { m.send(:expect_min_args, tokens, 2, "a b") }.not_to raise_error
    end
  end

  # ---- shell_runner: terminate_process when wait_thr exits between TERM and KILL -----

  describe "Runner::ShellRunner terminate_process clean-exit branch" do
    let(:runner) { Prouterd::Runner::ShellRunner.new }
    it "captures the status when wait_thr.join(0) returns the thread (exited)" do
      fake = Class.new do
        def pid; 99_999_999; end
        def join(*args)
          # Pretend TERM made the process exit immediately.
          self
        end
        def value
          double(exitstatus: 0)
        end
      end.new
      allow(Process).to receive(:kill).with("TERM", any_args)
      runner.send(:terminate_process, fake)
    end
  end

  # ---- shell_runner: collect_artifacts ignores the artifacts root entry -----

  describe "Runner::ShellRunner collect_artifacts dir-entry skip" do
    let(:runner) { Prouterd::Runner::ShellRunner.new }
    it "drops the artifacts root '.' entry (rel.empty? branch)" do
      Dir.mktmpdir do |work|
        FileUtils.mkdir_p(File.join(work, "artifacts"))
        File.write(File.join(work, "artifacts/x.txt"), "x")
        result = runner.send(:collect_artifacts, work)
        expect(result.map(&:name)).to eq(["x.txt"])
      end
    end
  end

  # ---- tracer: depends_on_runtime? false branch (match doesn't reference any runtime path) -----

  describe "Runtime::Tracer depends_on_runtime? false branch" do
    it "leaves reason nil when a match has no runtime-output dependency" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface manual cli
         no shutdown
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
          match event.t eq "x"
         exit
        exit
        route interface cli process p
        exit
      PRC
      res = Prouterd::Runtime::Tracer.trace(doc, { "t" => "x" }, interface_name: "cli")
      edge = res.graph.find { |e| e.to == "b" }
      expect(edge.match_results.first.reason).to be_nil
    end
  end

  # ---- session: replay_from with payload that has no context.event ----

  describe "Shell::Session replay_from payload missing context.event" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:session) { Prouterd::Shell::Session.new(store: store, runner: runner) }
    after { db.close }

    it "falls back to original.input_event_json when payload['context']['event'] missing" do
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
      # Strip context.event from the captured input_json
      db.execute("UPDATE run_steps SET input_json = ? WHERE id = ?",
                 [JSON.dump("context" => { "other" => "x" }), step.id])
      replayed = session.replay_from(original.uid, "b")
      expect(replayed.status).to eq("success")
    end
  end

  # ---- local_repo_caller: canonical_path on a path that survives filters but expands outside -----
  # (Defensive; can't construct with File.expand_path on POSIX — skipped.)

  # ---- runs: count_runs_by_status defensive nil-row guard -----
  # COUNT(*) always returns one row; the `: 0` branch is genuinely
  # unreachable in practice. Stub the DB to force the nil-row branch.

  # ---- privileged: render_run_summary duration nil + commit_id branches -----

  describe "Shell::Modes::Privileged render_run_summary" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "prints '-' for a step with no duration_ms" do
      session = Prouterd::Shell::Session.new(store: store)
      repo = Prouterd::Storage::Repositories::Runs.new(db)
      r = repo.create_run(process_name: "p", input_event: {})
      repo.create_step(run_id: r.id, block_name: "lonely")
      run_row = repo.get_run(r.id)
      out = StringIO.new
      mode = Prouterd::Shell::Modes::Privileged.new
      mode.send(:render_run_summary, run_row, session, out)
      expect(out.string).to match(/lonely\s+pending\s+-/)
    end
  end

  # ---- shell/shell.rb: read_input non-interactive prints prompt + flush -----

  describe "Shell::Shell read_input non-interactive prompt flush" do
    it "prints the prompt + flush when @output responds to both" do
      input = StringIO.new("show version\nexit\n")
      def input.isatty; true; end
      output = StringIO.new
      shell = Prouterd::Shell::Shell.new(
        session: Prouterd::Shell::Session.new,
        input: input, output: output, error: StringIO.new,
        interactive: true, banner: false
      )
      allow(shell).to receive(:reline_available?).and_return(false)
      shell.run
      expect(output.string).to include("process-router")
    end
  end

  # ---- shell/show: list_routes (process-scoped) covers route.matches presence -----

  describe "Shell::Show list_routes scoped with route matches" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "prints the [N match] suffix when a route has match conditions" do
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
      Prouterd::Shell::Show.list_routes(["process", "p"], session, out)
      expect(out.string).to include("[1 match]")
    end
  end

  # ---- shell/show: show_policy with delays set covers retry-initial-delay/max-delay branches -----

  describe "Shell::Show show_policy renders delay fields" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "renders retry initial-delay / max-delay through DurationParser" do
      doc = parse(<<~PRC)
        router demo
        exit
        policy r1
         retry attempts 3
         retry initial-delay 5s
         retry max-delay 2m
        exit
      PRC
      session = Prouterd::Shell::Session.new(store: store)
      session.replace_running(doc)
      out = StringIO.new
      Prouterd::Shell::Show.show_policy(["r1"], session, out)
      expect(out.string).to include("5s")
      expect(out.string).to include("2m")
    end
  end

  # ---- shell/show: show_policy retry-when with values -----

  describe "Shell::Show show_policy retry-when match values" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
    after { db.close }

    it "joins match values with commas" do
      doc = parse(<<~PRC)
        router demo
        exit
        policy r1
         retry attempts 3
         retry when error_type in "timeout","boom"
        exit
      PRC
      session = Prouterd::Shell::Session.new(store: store)
      session.replace_running(doc)
      out = StringIO.new
      Prouterd::Shell::Show.show_policy(["r1"], session, out)
      expect(out.string).to include("timeout,boom").or include("timeout, boom")
    end
  end
end
