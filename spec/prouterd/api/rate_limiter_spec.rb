require "spec_helper"

RSpec.describe Prouterd::API::RateLimiter do
  it "allows up to max within the window then refuses" do
    rl = described_class.new(max_requests: 3, window_seconds: 1)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(false)
  end

  it "tracks separate buckets per key" do
    rl = described_class.new(max_requests: 2, window_seconds: 1)
    expect(rl.allow?("a")).to be(true)
    expect(rl.allow?("a")).to be(true)
    expect(rl.allow?("a")).to be(false)
    expect(rl.allow?("b")).to be(true)
  end

  it "trims the window on each call" do
    rl = described_class.new(max_requests: 2, window_seconds: 0.1)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(false)
    sleep 0.15
    expect(rl.allow?("k")).to be(true)
  end

  it "from_env parses the PROUTERD_WEBHOOK_RATE format" do
    ENV["PROUTERD_WEBHOOK_RATE"] = "5/2"
    begin
      rl = described_class.from_env
      5.times { expect(rl.allow?("k")).to be(true) }
      expect(rl.allow?("k")).to be(false)
    ensure
      ENV.delete("PROUTERD_WEBHOOK_RATE")
    end
  end

  it "from_env falls back to defaults on bad spec" do
    ENV["PROUTERD_WEBHOOK_RATE"] = "garbage"
    begin
      rl = described_class.from_env
      expect(rl).to be_a(described_class)
    ensure
      ENV.delete("PROUTERD_WEBHOOK_RATE")
    end
  end

  it "is thread-safe" do
    rl = described_class.new(max_requests: 100, window_seconds: 1)
    threads = 10.times.map { Thread.new { 50.times { rl.allow?("k") } } }
    threads.each(&:join)
    # 500 calls, max 100 in window — most rejected, none crashed.
    expect(rl.stats("k")).to be <= 100
  end
end
