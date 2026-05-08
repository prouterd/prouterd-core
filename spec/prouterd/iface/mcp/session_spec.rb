require "spec_helper"

RSpec.describe Prouterd::Iface::Mcp::Session do
  let(:fake_path) { File.expand_path("../../../fixtures/fake_mcp_server.rb", __dir__) }
  let(:argv)      { ["ruby", fake_path] }

  def session(env: {})
    s = described_class.new(argv: argv, env: env)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    s
  end

  it "completes initialize handshake and discovers tools" do
    s = session
    expect(s.tools.map { |t| t["name"] }).to eq(["echo"])
    expect(s.tools.first["inputSchema"]).to be_a(Hash)
  ensure
    s&.stop
  end

  it "round-trips a tools/call and returns the content array" do
    s = session
    response = s.call_tool("echo", { "msg" => "hi" }, timeout_seconds: 3)
    expect(response["content"]).to be_an(Array)
    text = response["content"].first["text"]
    payload = JSON.parse(text)
    expect(payload).to include("tool" => "echo", "args" => { "msg" => "hi" })
  ensure
    s&.stop
  end

  it "threads `env` through to the subprocess" do
    s = session(env: { "JIRA_TOKEN" => "secret-xyz" })
    response = s.call_tool("echo", {}, timeout_seconds: 3)
    payload = JSON.parse(response["content"].first["text"])
    expect(payload["env_jira"]).to eq("secret-xyz")
  ensure
    s&.stop
  end

  it "raises CallError when the server returns a JSON-RPC error frame" do
    s = described_class.new(argv: argv, env: { "MCP_FAKE_FAIL" => "1" })
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    expect {
      s.call_tool("anything", {}, timeout_seconds: 3)
    }.to raise_error(described_class::CallError, /fake server fail/)
  ensure
    s&.stop
  end

  it "raises TimeoutError when a call exceeds its timeout" do
    s = described_class.new(argv: argv, env: { "MCP_FAKE_DELAY" => "5" })
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    expect {
      s.call_tool("echo", { "msg" => "slow" }, timeout_seconds: 0.5)
    }.to raise_error(described_class::TimeoutError)
  ensure
    s&.stop
  end

  it "muxes concurrent tool calls over one stdio session via id correlation" do
    s = session(env: { "MCP_FAKE_DELAY" => "0.2" })
    threads = 5.times.map do |i|
      Thread.new do
        resp = s.call_tool("echo", { "msg" => "from-#{i}" }, timeout_seconds: 5)
        JSON.parse(resp["content"].first["text"])["args"]["msg"]
      end
    end
    expect(threads.map(&:value).sort).to eq((0..4).map { |i| "from-#{i}" })
  ensure
    s&.stop
  end

  it "raises StartError when argv resolves to nothing" do
    bad = described_class.new(argv: ["/no/such/binary"])
    expect { bad.start }.to raise_error(described_class::StartError, /spawn failed/)
  end

  it "raises ClosedError when call is attempted after stop" do
    s = session
    s.stop
    expect {
      s.call_tool("echo", {}, timeout_seconds: 1)
    }.to raise_error(described_class::ClosedError)
  end
end

RSpec.describe Prouterd::Iface::Mcp::ServerCommand do
  describe ".resolve" do
    it "npx maps to `npx -y <spec>`" do
      argv = described_class.resolve("kind" => "npx", "spec" => "@a/b@1")
      expect(argv).to eq(["npx", "-y", "@a/b@1"])
    end

    it "bin requires absolute path and returns it as a one-element argv" do
      argv = described_class.resolve("kind" => "bin", "spec" => "/usr/local/bin/foo")
      expect(argv).to eq(["/usr/local/bin/foo"])
      expect {
        described_class.resolve("kind" => "bin", "spec" => "foo")
      }.to raise_error(described_class::ResolveError, /must be absolute/)
    end

    it "raw shell-tokenises the spec" do
      argv = described_class.resolve("kind" => "raw",
                                     "spec" => 'docker run --rm -i some/image:tag')
      expect(argv).to eq(["docker", "run", "--rm", "-i", "some/image:tag"])
    end

    it "rejects empty / unknown kinds" do
      expect {
        described_class.resolve("kind" => "raw", "spec" => "")
      }.to raise_error(described_class::ResolveError, /empty/)
      expect {
        described_class.resolve("kind" => "gem", "spec" => "x")
      }.to raise_error(described_class::ResolveError, /unknown server kind/)
    end
  end

  describe ".warn_if_unresolvable" do
    it "warns on a non-existent bin path" do
      msg = described_class.warn_if_unresolvable("kind" => "bin",
                                                  "spec" => "/no/such/path")
      expect(msg).to include("does not exist")
    end

    it "yellow-flags raw as unverifiable" do
      msg = described_class.warn_if_unresolvable("kind" => "raw", "spec" => "anything")
      expect(msg).to include("cannot be validated")
    end
  end
end
