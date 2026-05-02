require "spec_helper"

RSpec.describe Prouterd::API::RateLimiter, "bucket eviction" do
  it "drops empty buckets after the eviction interval so the map doesn't leak" do
    rl = described_class.new(max_requests: 10, window_seconds: 1)
    100.times { |i| rl.allow?("iface_#{i}") }
    expect(rl.bucket_count).to eq(100)

    # Force the eviction-window past, simulate quiet period.
    rl.instance_variable_set(:@last_evict, Time.now.to_f - 120)

    # First call after the interval triggers eviction. Make sure the
    # tracked-bucket has aged out of the window first.
    rl.instance_variable_get(:@buckets).each_value(&:clear)

    rl.allow?("fresh")
    expect(rl.bucket_count).to be <= 1
  end

  it "still rejects bursts exceeding max_requests" do
    rl = described_class.new(max_requests: 3, window_seconds: 60)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(true)
    expect(rl.allow?("k")).to be(false)
  end
end
