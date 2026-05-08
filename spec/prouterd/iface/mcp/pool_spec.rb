require "spec_helper"

RSpec.describe Prouterd::Iface::Mcp::Pool do
  let(:fake_path) { File.expand_path("../../../fixtures/fake_mcp_server.rb", __dir__) }

  # NullSecretResolver for these tests — secrets aren't load-bearing.
  let(:secret_resolver) do
    Class.new {
      def resolve(_)
        ""
      end
    }.new
  end

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def doc(server_kind: "raw", spec: nil)
    spec ||= "ruby #{fake_path}"
    parse(<<~PRC)
      router demo
      exit
      interface mcp fake
       server #{server_kind} "#{spec}"
      exit
    PRC
  end

  it "spawns one session per interface mcp and discovers its tools" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    expect(pool.health["fake"][:state]).to eq(:ready)
    expect(pool.health["fake"][:tools]).to eq(["echo"])
  ensure
    pool&.stop
  end

  it "dispatches a namespaced tool call through the right session" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    result = pool.call_tool("fake.echo", { "msg" => "hi" })
    expect(result[:output_json]).to include("tool" => "echo")
  ensure
    pool&.stop
  end

  it "returns mcp_unavailable when the namespace is unknown" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    result = pool.call_tool("ghost.thing", {})
    expect(result[:error_type]).to eq("mcp_unavailable")
  ensure
    pool&.stop
  end

  it "returns unknown_tool when the namespace is right but the tool isn't advertised" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    result = pool.call_tool("fake.never_existed", {})
    expect(result[:error_type]).to eq("unknown_tool")
  ensure
    pool&.stop
  end

  it "tool_snapshot returns the live descriptors per requested iface" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    snap = pool.tool_snapshot(%w[fake nonexistent])
    expect(snap["fake"].first["name"]).to eq("echo")
    expect(snap["nonexistent"]).to eq([])
  ensure
    pool&.stop
  end

  it "marks an interface degraded when the spawn argv resolves to nothing" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc(server_kind: "bin", spec: "/no/such/binary"))
    expect(pool.health["fake"][:state]).to eq(:degraded)
    expect(pool.health["fake"][:last_error]).to be_a(String)
  ensure
    pool&.stop
  end

  it "stops removed interfaces on reconcile" do
    pool = described_class.new(secret_resolver: secret_resolver)
    pool.start_or_reconcile(doc)
    pool.start_or_reconcile(parse("router x\nexit\n"))
    expect(pool.health).to be_empty
  ensure
    pool&.stop
  end
end
