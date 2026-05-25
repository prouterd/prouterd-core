require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Iface::Mcp::Session do
  let(:fake_path) { File.expand_path("../../../fixtures/fake_mcp_server.rb", __dir__) }
  let(:argv)      { ["ruby", fake_path] }

  it "raises StartError when argv resolves to nothing" do
    s = described_class.new(argv: ["/no/such/binary"])
    expect { s.start }.to raise_error(described_class::StartError, /spawn failed/)
  end

  it "times out the initialize_handshake when the server is hung" do
    # A binary that holds stdout open but never writes anything → the
    # reader_loop never dispatches a response → handshake times out.
    hang = Tempfile.create(["mcp-hang-", ".sh"])
    hang.write("#!/bin/sh\nsleep 10\n")
    hang.close
    File.chmod(0o755, hang.path)

    s = described_class.new(argv: [hang.path])
    s.start
    expect {
      s.initialize_handshake(timeout_seconds: 0.2)
    }.to raise_error(described_class::TimeoutError, /initialize/)
  ensure
    s&.stop
    File.unlink(hang.path) if hang
  end

  it "raises CallError on tools/list when the server returns an error frame" do
    fake_tools_error = Tempfile.create(["mcp-list-err-", ".rb"])
    fake_tools_error.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
        when "tools/list"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id,
                                  "error" => { "code" => -32000, "message" => "no list for you" })
        end
      end
    RUBY
    fake_tools_error.close

    s = described_class.new(argv: ["ruby", fake_tools_error.path])
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    expect {
      s.list_tools(timeout_seconds: 3)
    }.to raise_error(described_class::CallError, /no list for you/)
  ensure
    s&.stop
    File.unlink(fake_tools_error.path) if fake_tools_error
  end

  it "raises CallError when the server returns an error frame for tools/call (covers error.data)" do
    s = described_class.new(argv: argv, env: { "MCP_FAKE_FAIL" => "1" })
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    expect {
      s.call_tool("echo", {}, timeout_seconds: 3)
    }.to raise_error(described_class::CallError) do |err|
      expect(err.code).to eq(-32000)
      # data is not set by the fake; reader allows nil
      expect(err.data).to be_nil
    end
  ensure
    s&.stop
  end

  it "is idempotent on stop (calling twice is a no-op)" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    s.stop
    expect { s.stop }.not_to raise_error
    expect(s.alive?).to be false
  end

  it "reports alive? false after the wait_thr exits" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    expect(s.alive?).to be true
    s.stop
    expect(s.alive?).to be false
  end

  it "exposes a defensive copy via stderr_tail" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    tail = s.stderr_tail
    expect(tail).to be_an(Array)
    # Mutating the returned copy must not affect the session's buffer.
    tail << "outside"
    expect(s.stderr_tail).not_to include("outside")
  ensure
    s&.stop
  end

  it "reader_loop logs but tolerates non-JSON stdout lines" do
    fake_logger = double("logger", warn: nil, debug: nil, info: nil, error: nil)
    expect(fake_logger).to receive(:warn).with(
      "mcp non-JSON stdout", hash_including(facility: "MCP", mnemonic: "BAD_FRAME")
    ).at_least(:once)

    fake_garbage = Tempfile.create(["mcp-garbage-", ".rb"])
    fake_garbage.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      # Emit one garbage line that the reader_loop must rescue.
      $stdout.puts "not-json-frame"
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
        when "tools/list"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => { "tools" => [] })
        end
      end
    RUBY
    fake_garbage.close

    s = described_class.new(argv: ["ruby", fake_garbage.path], logger: fake_logger)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    # Give the reader a tick to process the garbage line.
    sleep 0.05
  ensure
    s&.stop
    File.unlink(fake_garbage.path) if fake_garbage
  end

  it "logs notifications (no-id frames) at debug level" do
    fake_logger = double("logger", warn: nil, debug: nil, info: nil, error: nil)
    expect(fake_logger).to receive(:debug).with(
      "mcp notification", hash_including(facility: "MCP", mnemonic: "NOTIFY")
    ).at_least(:once)

    fake_notif = Tempfile.create(["mcp-notif-", ".rb"])
    fake_notif.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "method" => "notifications/tools/list_changed", "params" => {})
        when "tools/list"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => { "tools" => [] })
        end
      end
    RUBY
    fake_notif.close

    s = described_class.new(argv: ["ruby", fake_notif.path], logger: fake_logger)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    sleep 0.05
  ensure
    s&.stop
    File.unlink(fake_notif.path) if fake_notif
  end

  it "honours cwd when set" do
    Dir.mktmpdir do |dir|
      s = described_class.new(argv: argv, cwd: dir)
      s.start
      s.initialize_handshake(timeout_seconds: 3)
      s.list_tools(timeout_seconds: 3)
      expect(s.tools.first["name"]).to eq("echo")
      s.stop
    end
  end

  it "drains stderr lines into the stderr_tail buffer" do
    fake = Tempfile.create(["mcp-stderr-", ".rb"])
    fake.write(<<~'RUBY')
      require "json"
      $stderr.puts "starting server"
      $stderr.flush
      $stdout.sync = true
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
        end
      end
    RUBY
    fake.close

    s = described_class.new(argv: ["ruby", fake.path])
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    # Give the stderr_loop a tick to see the line.
    sleep 0.1
    expect(s.stderr_tail).to include(a_string_matching(/starting server/))
  ensure
    s&.stop
    File.unlink(fake.path) if fake
  end

  it "raises ClosedError from request when stdin is closed mid-write" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    # Force the next write to raise EPIPE / IOError.
    stdin = s.instance_variable_get(:@stdin)
    stdin.close
    expect {
      s.call_tool("echo", {}, timeout_seconds: 1)
    }.to raise_error(described_class::ClosedError, /stdin closed/)
  ensure
    s&.stop
  end

  it "alive? is falsy before start (covers @wait_thread&. nil branch)" do
    s = described_class.new(argv: argv)
    expect(s.alive?).to be_falsey
  end

  it "stop is a fast no-op the second time around" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    s.stop
    # @closed is now true; second call should exit immediately.
    expect { s.stop }.not_to raise_error
  end

  it "stderr_tail caps at @stderr_cap entries (covers shift then-branch)" do
    fake = Tempfile.create(["mcp-flood-", ".rb"])
    fake.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      # Spew >100 stderr lines (the default cap).
      120.times { |i| $stderr.puts "line-#{i}" }
      $stderr.flush
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
        end
      end
    RUBY
    fake.close

    s = described_class.new(argv: ["ruby", fake.path])
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    sleep 0.2
    # Cap is 100, we sent 120 → buffer must be exactly 100 entries.
    expect(s.stderr_tail.length).to eq(100)
  ensure
    s&.stop
    File.unlink(fake.path) if fake
  end

  it "reader_loop skips blank stdout lines" do
    fake = Tempfile.create(["mcp-blanks-", ".rb"])
    fake.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      while (line = $stdin.gets)
        line.strip!; next if line.empty?
        frame = JSON.parse(line) rescue next
        id = frame["id"]
        case frame["method"]
        when "initialize"
          # Emit a blank line before the response → reader_loop must skip.
          $stdout.puts ""
          $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
        end
      end
    RUBY
    fake.close

    s = described_class.new(argv: ["ruby", fake.path])
    s.start
    expect { s.initialize_handshake(timeout_seconds: 3) }.not_to raise_error
  ensure
    s&.stop
    File.unlink(fake.path) if fake
  end

  it "dispatch_response ignores frames whose id has no matching waiter" do
    s = described_class.new(argv: argv)
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    # Direct send: id 999 has no waiter; method must NOT raise.
    expect {
      s.send(:dispatch_response, 999, { "id" => 999, "result" => {} })
    }.not_to raise_error
  ensure
    s&.stop
  end

  it "swallows ESRCH from Process.kill('KILL', ...) when the pid vanished mid-escalation" do
    fake = Tempfile.create(["mcp-noterm-esrch-", ".rb"])
    fake.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      Signal.trap("TERM") { }
      Thread.new do
        while (line = $stdin.gets)
          line.strip!; next if line.empty?
          frame = JSON.parse(line) rescue next
          id = frame["id"]
          case frame["method"]
          when "initialize"
            $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
          when "tools/list"
            $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => { "tools" => [] })
          end
        end
      end
      loop { sleep 0.05 }
    RUBY
    fake.close

    s = described_class.new(argv: ["ruby", fake.path])
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    allow(Process).to receive(:kill).and_call_original
    allow(Process).to receive(:kill).with("KILL", anything).and_raise(Errno::ESRCH)
    allow(s.instance_variable_get(:@wait_thread)).to receive(:join).and_return(nil)
    expect { s.stop(grace_seconds: 0.1) }.not_to raise_error
  ensure
    File.unlink(fake.path) if fake
    begin; Process.kill("KILL", s.instance_variable_get(:@wait_thread)&.pid); rescue StandardError; end
  end

  it "escalates to KILL when TERM is ignored during stop" do
    fake = Tempfile.create(["mcp-noterm-", ".rb"])
    fake.write(<<~'RUBY')
      require "json"
      $stdout.sync = true
      # Ignore TERM AND keep the process alive even after stdin EOFs.
      Signal.trap("TERM") { }
      Thread.new do
        while (line = $stdin.gets)
          line.strip!; next if line.empty?
          frame = JSON.parse(line) rescue next
          id = frame["id"]
          case frame["method"]
          when "initialize"
            $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => {})
          when "tools/list"
            $stdout.puts JSON.dump("jsonrpc" => "2.0", "id" => id, "result" => { "tools" => [] })
          end
        end
      end
      # Spin forever; TERM is trapped, so only KILL can stop us.
      loop { sleep 0.05 }
    RUBY
    fake.close

    s = described_class.new(argv: ["ruby", fake.path])
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)
    # Stop with a tiny grace so the KILL escalation fires quickly.
    s.stop(grace_seconds: 0.3)
    expect(s.alive?).to be_falsey
  ensure
    File.unlink(fake.path) if fake
  end

  it "wakes in-flight callers with ClosedError when stop is invoked" do
    s = described_class.new(argv: argv, env: { "MCP_FAKE_DELAY" => "2" })
    s.start
    s.initialize_handshake(timeout_seconds: 3)
    s.list_tools(timeout_seconds: 3)

    woke = nil
    t = Thread.new do
      begin
        s.call_tool("echo", { "msg" => "x" }, timeout_seconds: 5)
        woke = :unexpected_ok
      rescue described_class::ClosedError
        woke = :closed
      rescue described_class::TimeoutError
        woke = :timeout
      end
    end
    sleep 0.1
    s.stop
    t.join(2)
    expect(woke).to eq(:closed)
  end
end

RSpec.describe "Iface::Mcp::Session io.close rescue" do
  it "swallows StandardError raised by io.close during stop" do
    session = Prouterd::Iface::Mcp::Session.new(argv: ["/usr/bin/true"], env: {})
    # Inject ivars without actually starting a process
    bad_io = Object.new
    def bad_io.close; raise StandardError, "io.close blew up"; end
    session.instance_variable_set(:@stdin, bad_io)
    session.instance_variable_set(:@stdout, nil)
    session.instance_variable_set(:@stderr, nil)
    session.instance_variable_set(:@waiters, {})
    session.instance_variable_set(:@waiters_lock, Mutex.new)
    session.instance_variable_set(:@reader_thread, nil)
    session.instance_variable_set(:@stderr_thread, nil)
    session.instance_variable_set(:@wait_thread, nil)
    session.instance_variable_set(:@state, :ready)
    session.instance_variable_set(:@state_lock, Mutex.new)
    expect { session.stop(grace_seconds: 0) }.not_to raise_error
  end
end
