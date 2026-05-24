require "spec_helper"

RSpec.describe Prouterd::Iface::Mcp::Pool do
  let(:fake_path) { File.expand_path("../../../fixtures/fake_mcp_server.rb", __dir__) }

  let(:secret_resolver) do
    Class.new {
      def resolve(secret)
        "resolved-#{secret.name}" rescue ""
      end
    }.new
  end

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def doc(server_kind: "raw", spec: nil, secret_decl: nil, iface_extra: "")
    spec ||= "ruby #{fake_path}"
    prc = +"router demo\nexit\n"
    prc << "secret #{secret_decl}\n" if secret_decl
    prc << <<~PRC
      interface mcp fake
       server #{server_kind} "#{spec}"
       #{iface_extra}
      exit
    PRC
    parse(prc)
  end

  describe "call_tool error mapping" do
    it "bad_tool_name when no dot in the namespaced name" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      result = pool.call_tool("no_dot_name", {})
      expect(result[:error_type]).to eq("bad_tool_name")
    ensure
      pool&.stop
    end

    it "mcp_unavailable when the iface exists but is not ready" do
      pool = described_class.new(secret_resolver: secret_resolver)
      # Use a bad bin so the entry goes :degraded
      pool.start_or_reconcile(doc(server_kind: "bin", spec: "/no/such/binary"))
      result = pool.call_tool("fake.anything", {})
      expect(result[:error_type]).to eq("mcp_unavailable")
    ensure
      pool&.stop
    end

    it "translates Session::TimeoutError into error_type=timeout" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      entry = pool.instance_variable_get(:@entries)["fake"]
      allow(entry.session).to receive(:call_tool).and_raise(
        Prouterd::Iface::Mcp::Session::TimeoutError.new("server slow")
      )
      result = pool.call_tool("fake.echo", {})
      expect(result[:error_type]).to eq("timeout")
      expect(result[:error_message]).to include("server slow")
    ensure
      pool&.stop
    end

    it "translates Session::CallError into mcp_call_error" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      entry = pool.instance_variable_get(:@entries)["fake"]
      allow(entry.session).to receive(:call_tool).and_raise(
        Prouterd::Iface::Mcp::Session::CallError.new("call boom")
      )
      result = pool.call_tool("fake.echo", {})
      expect(result[:error_type]).to eq("mcp_call_error")
    ensure
      pool&.stop
    end

    it "translates Session::ClosedError into mcp_unavailable and marks the entry degraded" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      entry = pool.instance_variable_get(:@entries)["fake"]
      allow(entry.session).to receive(:call_tool).and_raise(
        Prouterd::Iface::Mcp::Session::ClosedError.new("subprocess gone")
      )
      result = pool.call_tool("fake.echo", {})
      expect(result[:error_type]).to eq("mcp_unavailable")
      expect(pool.health["fake"][:state]).to eq(:degraded)
    ensure
      pool&.stop
    end
  end

  describe "normalise_call_result" do
    it "parses single-text content as JSON when valid" do
      pool = described_class.new(secret_resolver: secret_resolver)
      out = pool.send(:normalise_call_result,
                      "content" => [{ "type" => "text", "text" => '{"a":1}' }])
      expect(out).to eq("a" => 1)
    end

    it "wraps plain text content as {text: ...} when not JSON" do
      pool = described_class.new(secret_resolver: secret_resolver)
      out = pool.send(:normalise_call_result,
                      "content" => [{ "type" => "text", "text" => "raw text" }])
      expect(out).to eq("text" => "raw text")
    end

    it "preserves full structure when content has multiple parts" do
      pool = described_class.new(secret_resolver: secret_resolver)
      out = pool.send(:normalise_call_result,
                      "content" => [{ "type" => "text", "text" => "a" },
                                    { "type" => "image" }],
                      "isError" => true)
      expect(out["content"].length).to eq(2)
      expect(out["isError"]).to eq(true)
    end
  end

  describe "tool_snapshot" do
    it "returns empty arrays for unknown ifaces" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      expect(pool.tool_snapshot(["nope"])).to eq("nope" => [])
    ensure
      pool&.stop
    end

    it "returns [] for an iface that exists but is not :ready" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc(server_kind: "bin", spec: "/no/such/binary"))
      expect(pool.tool_snapshot(["fake"])).to eq("fake" => [])
    ensure
      pool&.stop
    end
  end

  describe "mark_degraded backoff doubling" do
    it "escalates backoff_seconds and sets next_retry_at on repeated marks" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc(server_kind: "bin", spec: "/no/such/binary"))
      entry = pool.instance_variable_get(:@entries)["fake"]
      first = entry.backoff_seconds
      pool.send(:mark_degraded, "fake", "second failure")
      second = entry.backoff_seconds
      expect(second).to be > first
      expect(entry.next_retry_at).to be_a(Time)
    ensure
      pool&.stop
    end

    it "is a no-op when the iface_name is unknown" do
      pool = described_class.new(secret_resolver: secret_resolver)
      expect { pool.send(:mark_degraded, "ghost", "x") }.not_to raise_error
    end
  end

  describe "record_failure (server unresolvable)" do
    it "stores the entry as degraded with last_error populated" do
      pool = described_class.new(secret_resolver: secret_resolver)
      # An unknown kind triggers ServerCommand::ResolveError → record_failure.
      pool.start_or_reconcile(doc(server_kind: "raw", spec: ""))
      entry = pool.instance_variable_get(:@entries)["fake"]
      expect(entry.state).to eq(:degraded)
      expect(entry.last_error).to include("server_unresolvable")
    ensure
      pool&.stop
    end
  end

  describe "retry_loop with @stopping" do
    it "bails out immediately when @stopping is already true" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.instance_variable_set(:@stopping, true)
      expect { pool.send(:retry_loop) }.not_to raise_error
    end

    it "logs RETRY_CRASH when an unexpected exception escapes the loop body" do
      pool = described_class.new(secret_resolver: secret_resolver)
      logger = double("logger", info: nil, debug: nil, warn: nil, error: nil)
      pool.instance_variable_set(:@logger, logger)
      expect(logger).to receive(:error).with(
        "mcp retry thread crashed", hash_including(facility: "MCP", mnemonic: "RETRY_CRASH")
      ).at_least(:once)
      allow(pool).to receive(:tick).and_raise("simulated crash")
      pool.send(:retry_loop)
    end
  end

  describe "resolve_secrets" do
    it "skips secrets that aren't declared in the document" do
      pool = described_class.new(secret_resolver: secret_resolver)
      document = parse("router x\nexit\n")
      # Names not in document.secrets are silently skipped.
      out = pool.send(:resolve_secrets, ["GHOST"], document)
      expect(out).to eq({})
    end

    it "resolves declared secrets through the resolver" do
      pool = described_class.new(secret_resolver: secret_resolver)
      document = parse(<<~PRC)
        router x
        exit
        secret JIRA
         source env JIRA_TOKEN
        exit
      PRC
      out = pool.send(:resolve_secrets, ["JIRA"], document)
      expect(out).to eq("JIRA" => "resolved-JIRA")
    end
  end

  describe "start_or_reconcile drops removed interfaces" do
    it "stops the entry and removes it from @entries" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      expect(pool.instance_variable_get(:@entries)).to have_key("fake")
      pool.start_or_reconcile(parse("router x\nexit\n"))
      expect(pool.instance_variable_get(:@entries)).to be_empty
    ensure
      pool&.stop
    end
  end

  describe "stop_entry guards" do
    it "is a no-op when given nil" do
      pool = described_class.new(secret_resolver: secret_resolver)
      expect { pool.send(:stop_entry, nil) }.not_to raise_error
    end
  end

  describe "tick when the wanted entry disappears mid-retry" do
    it "skips entries removed from @wanted between the snapshot and the spawn" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc(server_kind: "bin", spec: "/no/such/binary"))
      entry = pool.instance_variable_get(:@entries)["fake"]
      entry.next_retry_at = Time.now - 1
      # Drop the wanted entry but force the select to see it via key?.
      wanted = pool.instance_variable_get(:@wanted)
      wanted.delete("fake")
      allow(wanted).to receive(:key?).with("fake").and_return(true)
      expect { pool.send(:tick) }.not_to raise_error
    ensure
      pool&.stop
    end
  end

  describe "spawn_session stderr_tail else branch" do
    it "tolerates a Session that doesn't respond_to?(:stderr_tail)" do
      pool = described_class.new(secret_resolver: secret_resolver)
      # Use real document so spawn argv resolves cleanly, then swap the
      # built Session with a stub that raises during start.
      stub = Object.new
      def stub.start; raise "stub start failure"; end
      def stub.stop; end
      # respond_to?(:stderr_tail) is false → covers the else branch.
      allow(Prouterd::Iface::Mcp::Session).to receive(:new).and_return(stub)

      pool.start_or_reconcile(doc)
      expect(pool.health["fake"][:state]).to eq(:degraded)
    ensure
      pool&.stop
    end
  end

  describe "health surface" do
    it "returns a snapshot keyed by iface name" do
      pool = described_class.new(secret_resolver: secret_resolver)
      pool.start_or_reconcile(doc)
      h = pool.health
      expect(h["fake"]).to include(state: :ready)
    ensure
      pool&.stop
    end
  end
end
