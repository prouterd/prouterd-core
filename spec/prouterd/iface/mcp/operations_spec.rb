require "spec_helper"
require "rack/test"
require "prouterd/cli/main"
require "tempfile"

RSpec.describe "Phase 39 ops: /v1/mcp + show mcp + validate warnings" do
  let(:fake_path) { File.expand_path("../../../fixtures/fake_mcp_server.rb", __dir__) }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "GET /v1/mcp" do
    include Rack::Test::Methods
    let(:db)     { Prouterd::Storage::DB.open(":memory:") }
    let(:store)  { Prouterd::ControlPlane::ConfigStore.new(db) }
    let(:runner) { Prouterd::Runner::StubRunner.new }
    let(:jobs)   { Prouterd::Storage::Repositories::Jobs.new(db) }
    let(:resolver) { Class.new { def resolve(_); ""; end }.new }
    let(:pool)   { Prouterd::Iface::Mcp::Pool.new(secret_resolver: resolver) }
    let(:app) do
      Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs, admin_token: nil,
        mcp_pool: pool
      )
    end

    after { db.close; pool.stop }

    it "returns declarations + live state from the pool" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp fake
         server raw "ruby #{fake_path}"
         timeout-tool-call 7s
        exit
      PRC
      store.commit(doc)
      pool.start_or_reconcile(doc)

      get "/v1/mcp"
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)["data"]
      expect(data.length).to eq(1)
      first = data.first
      expect(first["name"]).to eq("fake")
      expect(first["server"]).to eq("kind" => "raw", "spec" => "ruby #{fake_path}")
      expect(first["timeout_tool_call_ms"]).to eq(7000)
      expect(first["state"]).to eq("ready")
      expect(first["tools"]).to eq(["echo"])
    end

    it "reports state=no_pool when the daemon was started without one" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp fake
         server bin "/no/such/path"
        exit
      PRC
      store.commit(doc)
      no_pool_app = Prouterd::API::App.new(
        store: store, runner: runner, jobs: jobs, admin_token: nil
      )
      session = Rack::Test::Session.new(Rack::MockSession.new(no_pool_app))
      session.get "/v1/mcp"
      expect(JSON.parse(session.last_response.body)["data"].first["state"]).to eq("no_pool")
    end
  end

  describe "shell `show mcp`" do
    def drive(script, session:)
      input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
      output = StringIO.new
      error  = StringIO.new
      Prouterd::Shell::Shell.run(
        session: session, input: input, output: output, error: error,
        interactive: false, banner: false
      )
      [output.string, error.string]
    end

    it "lists declared mcp interfaces with the warn-if-unresolvable hint" do
      session = Prouterd::Shell::Session.new
      doc = parse(<<~PRC)
        router demo
        exit
        interface mcp atlassian
         server bin "/no/such/binary"
        exit
        interface mcp work
         server raw "ruby #{fake_path}"
        exit
      PRC
      session.replace_running(doc)
      out, err = drive("enable\nshow mcp\n", session: session)
      expect(err).to be_empty
      expect(out).to include("atlassian", "work")
      expect(out).to match(/atlassian.*does not exist/)
      expect(out).to match(/work.*cannot be validated/)
    end
  end

  describe "`prouter check` warns on unresolvable mcp server" do
    it "emits a warning for `bin` pointing at a nonexistent path" do
      file = Tempfile.new(["mcp", ".prc"])
      file.write(<<~PRC)
        router demo
        exit
        interface mcp x
         server bin "/no/such/binary"
        exit
      PRC
      file.flush

      stdout = StringIO.new
      stderr = StringIO.new
      exit_code = Prouterd::CLI::Main.run(
        ["check", file.path],
        stdin: StringIO.new, stdout: stdout, stderr: stderr
      )
      file.unlink
      expect(exit_code).to eq(0)
      expect(stdout.string).to match(/Warnings:/)
      expect(stdout.string).to match(/interface mcp 'x'.*does not exist/)
    end
  end

  describe "Pool reconcile on :config_changed" do
    after { Prouterd::Events.default.clear }

    it "fires an additional reconcile when the events bus publishes" do
      resolver = Class.new { def resolve(_); ""; end }.new
      pool = Prouterd::Iface::Mcp::Pool.new(secret_resolver: resolver)
      doc1 = parse("router x\nexit\n")
      pool.start_or_reconcile(doc1)
      expect(pool.health).to be_empty

      # Subscribe daemon-style; reload to a config that adds an iface.
      doc2 = parse(<<~PRC)
        router demo
        exit
        interface mcp fake
         server raw "ruby #{fake_path}"
        exit
      PRC

      Prouterd::Events.subscribe(:config_changed) do |_t, _p|
        pool.start_or_reconcile(doc2)
      end

      Prouterd::Events.publish(:config_changed, reason: "test")
      deadline = Time.now + 5
      sleep 0.05 while pool.health["fake"].nil? && Time.now < deadline

      expect(pool.health["fake"][:state]).to eq(:ready)
    ensure
      pool&.stop
    end
  end
end
