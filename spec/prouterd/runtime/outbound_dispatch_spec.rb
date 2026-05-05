require "spec_helper"
require "net/http"
require "json"

# Integration coverage for the new outbound caller dispatch (Phase 27).
#
# Drives the orchestrator end-to-end through CallRunner for each outbound
# interface plugin. Confirms that:
#   1. CallRunner finds the plugin's caller_class and invokes it via
#      `run(request)` (the contract DockerRunner / ShellRunner already used).
#   2. iface.type_fields are templated (so `dsn "{{secret.PG_DSN}}"` works).
#   3. The `secret.*` namespace resolves from document.secrets via the
#      configured secret_resolver.
#   4. Numeric path keys index into Arrays.
#
# Uses Net::HTTP stubbing (no network) for http and llm; pg is stubbed at
# the module level.
RSpec.describe "Phase 27 outbound dispatch + templating integration" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::CallRunner.new }
  let(:orch) do
    Prouterd::Runtime::Orchestrator.new(
      db: db, runner: runner,
      secret_resolver: stub_secret_resolver
    )
  end
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  # Resolves any secret to a fixed value derived from its name, so the
  # orchestrator's secret_resolver path is exercised without ENV mutation.
  def stub_secret_resolver
    Class.new do
      def resolve(secret); "resolved-#{secret.name}"; end
    end.new
  end

  # ----- HTTP dispatch -----

  describe "interface http" do
    before do
      response = Net::HTTPResponse.send(:response_class, "200").new("1.1", "200", "OK")
      response.instance_variable_set(:@body, JSON.dump("issue" => { "key" => "JIRA-7", "fields" => { "summary" => "from server" } }))
      response.instance_variable_set(:@read, true)

      @captured_request = nil
      adapter = Object.new
      adapter.define_singleton_method(:request) do |req|
        Thread.current[:captured_http] = {
          method: req.method, path: req.path,
          headers: req.each_header.to_h
        }
        response
      end
      allow(Net::HTTP).to receive(:start) do |_h, _p, **_o, &b|
        b.call(adapter)
      end
    end

    it "dispatches through CallRunner, templates path against the event payload" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret JIRA_TOKEN
         source env JIRA_TOKEN
        exit
        interface http jira
         base-url https://example.test/rest
         auth bearer secret JIRA_TOKEN
        exit
        process p
         block fetch
          interface http jira
          method GET
          path "/issue/{{event.key}}"
         exit
        exit
      PRC

      run = orch.trigger(doc, "p", input_event: { "key" => "JIRA-7" })
      expect(run.status).to eq("success")
      expect(repo.list_steps(run.id).map(&:status)).to eq(["success"])

      captured = Thread.current[:captured_http]
      expect(captured[:method]).to eq("GET")
      expect(captured[:path]).to eq("/rest/issue/JIRA-7")
      expect(captured[:headers]["authorization"]).to eq("Bearer resolved-JIRA_TOKEN")
    end

    it "exposes the response JSON to a downstream block via context[block_name]" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface http jira
         base-url https://example.test
        exit
        interface docker noop
         image alpine
        exit
        process p
         block fetch
          interface http jira
          method GET
          path "/x"
         exit
         block log_it
          interface docker noop
          command "got {{fetch.issue.key}}"
         exit
         route fetch log_it
        exit
      PRC

      seen_command = nil
      stub_runner = Prouterd::Runner::StubRunner.new
      stub_runner.program("log_it") do |req|
        seen_command = req.field("command")
        Prouterd::Runner::StubRunner.success.call(req)
      end

      # Use a hybrid runner: stub for docker, real CallRunner for http.
      hybrid = Class.new do
        def initialize(stub, call); @stub = stub; @call = call; end
        def run(request)
          if request.execution_type == "docker"
            @stub.run(request)
          else
            @call.run(request)
          end
        end
      end.new(stub_runner, runner)

      hybrid_orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: hybrid)
      hybrid_orch.trigger(doc, "p", input_event: {})
      expect(seen_command).to eq("got JIRA-7")
    end
  end

  # ----- Postgres dispatch with templated DSN from secret -----

  describe "interface postgres" do
    before do
      allow(Prouterd::Iface::PostgresCaller).to receive(:pg_available?).and_return(true)
      pg_double = Module.new
      pg_double.const_set(:Error, Class.new(StandardError))
      pg_double.const_set(:PG_DIAG_SQLSTATE, :sqlstate)
      pg_double.define_singleton_method(:connect) { |*| nil }
      stub_const("PG", pg_double)

      @conn = double("PG::Connection")
      allow(PG).to receive(:connect).and_return(@conn)
      allow(@conn).to receive(:exec)
      allow(@conn).to receive(:close)
    end

    it "templates iface.dsn from {{secret.PG_DSN}} before connecting" do
      doc = parse(<<~PRC)
        router demo
        exit
        secret PG_DSN
         source env PG_DSN
        exit
        interface postgres warehouse
         dsn "{{secret.PG_DSN}}"
        exit
        process p
         block lookup
          interface postgres warehouse
          query "SELECT 1"
         exit
        exit
      PRC

      result = double("PG::Result")
      allow(result).to receive(:map).and_return([])
      allow(result).to receive(:fields).and_return([])
      allow(result).to receive(:cmd_tuples).and_return(0)

      expect(PG).to receive(:connect).with("resolved-PG_DSN").and_return(@conn)
      expect(@conn).to receive(:exec).with("SELECT 1").and_return(result)

      run = orch.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
    end

    it "binds a templated array-indexed param into $1" do
      doc = parse(<<~PRC)
        router demo
        exit
        interface postgres warehouse
         dsn "postgres://x@h/db"
        exit
        process p
         block lookup
          interface postgres warehouse
          query "SELECT * FROM x WHERE c = $1"
          params "{{event.tags.0}}"
         exit
        exit
      PRC

      result = double("PG::Result")
      allow(result).to receive(:map).and_return([])
      allow(result).to receive(:fields).and_return([])
      allow(result).to receive(:cmd_tuples).and_return(0)

      expect(@conn).to receive(:exec_params)
        .with("SELECT * FROM x WHERE c = $1", ["urgent"])
        .and_return(result)

      run = orch.trigger(doc, "p", input_event: { "tags" => %w[urgent backend] })
      expect(run.status).to eq("success")
    end
  end
end
