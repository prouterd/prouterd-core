require "spec_helper"

RSpec.describe Prouterd::Iface::LlmSubprocess::Session do
  describe "#run" do
    it "raises ArgumentError if no block is given" do
      s = described_class.new(env: {}, argv: ["/bin/true"], timeout_ms: 1000)
      expect { s.run }.to raise_error(ArgumentError, /requires a block/)
    end

    it "runs with empty options (no cwd, no sandbox) — popen_args without options hash" do
      s = described_class.new(env: {}, argv: ["/bin/cat"], timeout_ms: 2000)
      result = s.run do |stdin, stdout, _handle|
        stdin.puts "hello"
        stdin.close_write
        stdout.read
      end
      expect(result.timed_out).to be(false)
      expect(result.value).to include("hello")
    end

    it "runs the ensure block (stdin.close + watchdog.kill) even when the block raises" do
      s = described_class.new(env: {}, argv: ["/bin/cat"], timeout_ms: 2000)
      expect {
        s.run do |_stdin, _stdout, _handle|
          raise "boom"
        end
      }.to raise_error("boom")
      # If the ensure ran we'd be back here; if not, the Open3.popen3 block
      # would hang the test (timeout).
    end

    it "marks the run as timed_out when the deadline expires" do
      # Sleep longer than the watchdog deadline — watchdog SIGTERMs
      # the process, the read returns, and timed_out flips to true.
      # Wait briefly inside the block for the flag to settle so we don't
      # race the watchdog's `timed_out_flag = true` assignment.
      s = described_class.new(env: {}, argv: ["/bin/sleep", "30"], timeout_ms: 300)
      result = s.run do |_stdin, stdout, handle|
        stdout.read # blocks until subprocess dies
        # Wait for watchdog to commit the flag (may still be in the
        # 50ms TERM/KILL gap when stdout returned EOF first).
        20.times { break if handle.timed_out?; sleep 0.05 }
      end
      expect(result.timed_out).to be(true)
      expect(result.status).to eq(:timeout)
    end
  end

  describe "Handle" do
    it "exposes the stderr buffer and timed_out? predicate" do
      buf = String.new
      flag = false
      h = described_class::Handle.new(stderr_buf: buf, timed_out_ref: -> { flag })
      expect(h.stderr_buf).to be(buf)
      expect(h.timed_out?).to be(false)
      flag = true
      expect(h.timed_out?).to be(true)
    end
  end
end
