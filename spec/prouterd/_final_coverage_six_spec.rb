require "spec_helper"
require "json"
require "stringio"
require "tempfile"
require "tmpdir"
require "open3"
require "rack/test"
require "prouterd/cli/main"

# Batch 6: targeted defensive branches via direct method calls.

RSpec.describe "Coverage mop-up — batch 6 (direct calls)" do
  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # ============================================================
  # local_repo_caller: gather with mocked git output to hit L94/L102
  # branches deterministically
  # ============================================================

  describe "Iface::LocalRepoCaller gather defensive parse branches" do
    let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

    def make_repo(root, name)
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir) do
        system("git init -q -b main")
        system("git config user.email t@t")
        system("git config user.name t")
        File.write("a", "1")
        system("git add . && git commit -q -m 'first'")
      end
      dir
    end

    it "handles a git log that ends with a blank line (commits << current if current)" do
      Dir.mktmpdir do |root|
        repo_dir = make_repo(root, "g")
        # Mock run_git to inject a controlled output that ends with a blank line
        canned_out = "sha1\tauthor\t1700000000\tsubject1\nfile1\n\n"
        canned_err = ""
        status = double("status", success?: true, exitstatus: 0)
        allow(caller_instance).to receive(:run_git).and_return([canned_out, canned_err, status])
        req = Prouterd::Runner::RunRequest.new(
          run_uid: "r", process_name: "p", block_name: "b",
          execution_type: "local_repo", attempt: 1, env: {},
          input_json: {}, timeout_ms: nil,
          type_fields: { "root" => root, "whitelist" => "g", "repo" => "g",
                         "call" => "gather", "branch" => "main" }
        )
        result = caller_instance.run(req)
        expect(result.error_type).to be_nil
        commits = result.output_json["commits"]
        expect(commits.length).to eq(1)
        expect(commits.first["sha"]).to eq("sha1")
        expect(commits.first["files"]).to eq(["file1"])
      end
    end

    it "handles consecutive blank lines (commits << current on first, then current nil on second)" do
      Dir.mktmpdir do |root|
        make_repo(root, "g")
        # Two commits with a double blank line between them
        canned_out = "sha1\ta\t100\tone\nfileA\n\n\nsha2\ta\t200\ttwo\nfileB\n"
        status = double("status", success?: true, exitstatus: 0)
        allow(caller_instance).to receive(:run_git).and_return([canned_out, "", status])
        req = Prouterd::Runner::RunRequest.new(
          run_uid: "r", process_name: "p", block_name: "b",
          execution_type: "local_repo", attempt: 1, env: {},
          input_json: {}, timeout_ms: nil,
          type_fields: { "root" => root, "whitelist" => "g", "repo" => "g",
                         "call" => "gather", "branch" => "main" }
        )
        result = caller_instance.run(req)
        commits = result.output_json["commits"]
        expect(commits.length).to eq(2)
      end
    end
  end

  # ============================================================
  # tracer: deep_stringify on a non-Hash, non-Array value (else branch)
  # ============================================================

  describe "Tracer.deep_stringify scalar/nil pass-through" do
    it "returns the value unchanged for nil" do
      tracer = Prouterd::Runtime::Tracer.new(
        Prouterd::Config::AST::Document.new, {}, nil
      )
      expect(tracer.send(:deep_stringify, nil)).to be_nil
      expect(tracer.send(:deep_stringify, 42)).to eq(42)
      expect(tracer.send(:deep_stringify, "x")).to eq("x")
    end
  end

  # ============================================================
  # retry_engine L92: result&.success? else branch (result is nil)
  # ============================================================

  describe "RetryEngine run_with_retries with nil result from yield" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:engine) { Prouterd::Runtime::RetryEngine.new(runs: runs) }

    it "returns nil when yield never produces a result (failed first attempt mid-loop)" do
      # When result is nil after the loop, the `result&.success?` is false,
      # so the policy-clamp doesn't reshape it.
      run = runs.create_run(process_name: "p", input_event: {})
      doc = parse("router demo\nexit\n")
      block = double(name: "b", retry_policy_name: nil)
      result = engine.run_with_retries(run, double(name: "p"), block,
                                        Prouterd::Runtime::Context.new({}),
                                        doc, Monitor.new, Monitor.new) do
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: {}, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 0, started_at: nil, finished_at: nil
        )
      end
      expect(result).not_to be_nil
    end
  end

  # ============================================================
  # cli/main: explicit ensure path with --no-db (store nil)
  # ============================================================

  describe "CLI::Main ensure paths with store == nil" do
    it "cmd_apply ensure no-op when store is nil (--no-db)" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        code = Prouterd::CLI::Main.run(["apply", t.path, "--no-db"],
                                        stdout: StringIO.new, stderr: StringIO.new)
        expect(code).to eq(0)
      end
    end

    it "cmd_validate ensure no-op when store is nil (--no-db + --against running)" do
      Tempfile.create(["good", ".prc"]) do |t|
        t.write(read_fixture("minimal.prc"))
        t.flush
        code = Prouterd::CLI::Main.run(
          ["validate", t.path, "--against", "running", "--no-db"],
          stdout: StringIO.new, stderr: StringIO.new
        )
        expect(code).to eq(0)
      end
    end
  end

  # ============================================================
  # api/v1: get_run_logs filtered by stream
  # ============================================================

  describe "API::V1 GET /v1/runs/:uid/logs filtered by stream" do
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

    it "filters log rows by ?stream= parameter" do
      doc = parse("router demo\nexit\n")
      store.commit(doc)
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      run = runs.create_run(process_name: "p", input_event: {})
      runs.append_log(run_id: run.id, stream: "stdout", content: "out-line")
      runs.append_log(run_id: run.id, stream: "stderr", content: "err-line")
      get "/v1/runs/#{run.uid}/logs", { "stream" => "stdout" }
      payload = JSON.parse(last_response.body)["data"]
      streams = payload.map { |l| l["stream"] }
      expect(streams).to all(eq("stdout"))
    end
  end

  # ============================================================
  # api/v1: post_run_replay use_current_config: true with no running pointer
  # → 409 conflict
  # ============================================================

  describe "API::V1 post_run_replay use_current_config conflict" do
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

    it "returns 409 when use_current_config is true but no running pointer exists" do
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
      run = Prouterd::Storage::Repositories::Runs.new(db).create_run(
        process_name: "p", input_event: {}, process_config_commit_id: store.running_commit.id
      )
      # Strip the running pointer so use_current_config has nothing to bind to
      db.execute("DELETE FROM config_pointers WHERE name = 'running'")
      post "/v1/runs/#{run.uid}/replay", JSON.dump(use_current_config: true),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(409)
    end
  end

  # ============================================================
  # api/v1: post_run_replay use_current_config: true with running pointer
  # ============================================================

  describe "API::V1 post_run_replay use_current_config success" do
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

    it "binds to the current running commit when use_current_config=true" do
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
      run = Prouterd::Storage::Repositories::Runs.new(db).create_run(
        process_name: "p", input_event: {}, process_config_commit_id: store.running_commit.id
      )
      post "/v1/runs/#{run.uid}/replay", JSON.dump(use_current_config: true),
           { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(202)
      expect(JSON.parse(last_response.body)["data"]["use_current_config"]).to be(true)
    end
  end
end
