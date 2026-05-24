require "spec_helper"
require "tmpdir"

# Coverage-extension specs for the small Session class that the
# subprocess LLM driver wraps Open3.popen3 with.
RSpec.describe Prouterd::Iface::LlmSubprocess::Session do
  describe "#run" do
    it "raises ArgumentError without a block" do
      session = described_class.new(env: {}, argv: ["/bin/true"], timeout_ms: 1_000)
      expect { session.run }.to raise_error(ArgumentError, /requires a block/)
    end

    it "fires the watchdog when the deadline is already in the past, setting timed_out" do
      # /bin/cat will block on stdin forever — perfect target for the
      # watchdog's TERM/KILL escalation.
      session = described_class.new(env: {}, argv: ["/bin/cat"], timeout_ms: 1)
      # Sleep just enough so Time.now > deadline by the time the loop runs.
      sleep 0.05
      result = session.run { |_stdin, _stdout, _handle| sleep 0.5 ; :ignored }
      expect(result.timed_out).to be true
      expect(result.status).to eq(:timeout)
    end

    it "Handle#timed_out? reflects the captured flag" do
      # /bin/echo exits immediately; handle.timed_out? must be false.
      session = described_class.new(env: {}, argv: ["/bin/echo", "hi"], timeout_ms: 5_000)
      seen = nil
      result = session.run do |_stdin, stdout, handle|
        stdout.read
        seen = handle.timed_out?
        handle.stderr_buf # touch accessor to exercise the wrapper
        :done
      end
      expect(seen).to be false
      expect(result.timed_out).to be false
      expect(result.value).to eq(:done)
    end

    it "propagates a block exception while still killing the watchdog and reaping the spawn" do
      session = described_class.new(env: {}, argv: ["/bin/cat"], timeout_ms: 5_000)
      expect {
        session.run { |_stdin, _stdout, _handle| raise "boom from block" }
      }.to raise_error(RuntimeError, /boom from block/)
    end

    it "status is wait_thr.value (a Process::Status) when the spawn finishes normally" do
      session = described_class.new(env: {}, argv: ["/bin/sh", "-c", "exit 0"], timeout_ms: 5_000)
      result = session.run { |_stdin, stdout, _handle| stdout.read; :ok }
      expect(result.status).to be_a(Process::Status)
      expect(result.status.success?).to be true
      expect(result.value).to eq(:ok)
    end

    it "passes spawn options (e.g. chdir) through when popen_options returns non-empty" do
      Dir.mktmpdir do |dir|
        session = described_class.new(env: {}, argv: ["/bin/sh", "-c", "pwd"],
                                       timeout_ms: 5_000, cwd: dir)
        result = session.run { |_stdin, stdout, _handle| stdout.read.chomp }
        # /bin/sh resolves /tmp/... possibly via /private/tmp/... on macOS;
        # we only assert the run completed with that cwd visible.
        expect(File.identical?(result.value, dir)).to be true
      end
    end

    it "omits the options hash when popen_options returns an empty hash" do
      # Default options path (no cwd, no sandbox) → popen_args is just env+argv.
      session = described_class.new(env: {}, argv: ["/bin/sh", "-c", "exit 0"], timeout_ms: 5_000)
      result = session.run { |_stdin, stdout, _handle| stdout.read; :done }
      expect(result.status.success?).to be true
    end

    it "defaults timeout_ms to DEFAULT_TIMEOUT_MS when nil is supplied" do
      session = described_class.new(env: {}, argv: ["/bin/echo", "hi"], timeout_ms: nil)
      result = session.run { |_stdin, stdout, _handle| stdout.read; :ok }
      expect(result.status.success?).to be true
    end
  end
end
