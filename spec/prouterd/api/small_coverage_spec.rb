require "spec_helper"
require "rack"

# Micro-specs for the small api/* files (Metrics, RateLimiter, Auth
# residual branch). Comprehensive flows live in their main specs;
# this file just nails the remaining conditional branches.

RSpec.describe Prouterd::API::Metrics do
  it "renders the header + uptime even with no in_flight wired" do
    metrics = described_class.new(in_flight: nil)
    out = metrics.render
    expect(out).to include("prouterd_uptime_seconds")
    expect(out).not_to include("prouterd_in_flight_runs")
  end

  it "renders prouterd_in_flight_runs from the registry when wired" do
    registry = double("in_flight", in_flight_count: 7)
    metrics = described_class.new(in_flight: registry)
    expect(metrics.render).to include("prouterd_in_flight_runs 7")
  end

  it "renders a labelled counter group" do
    metrics = described_class.new
    metrics.increment(:runs_total, process: "p1", status: "success")
    metrics.increment(:runs_total, by: 2, process: "p1", status: "success")
    out = metrics.render
    expect(out).to include('prouterd_runs_total{process="p1",status="success"} 3')
  end

  it "renders an unlabelled counter group" do
    metrics = described_class.new
    metrics.increment(:beans_total)
    out = metrics.render
    expect(out).to match(/prouterd_beans_total \d+/)
  end

  it "escapes backslash, quote, and newline in label values" do
    metrics = described_class.new
    metrics.increment(:edge_total, name: "a\\b\"c\nd")
    out = metrics.render
    expect(out).to include('name="a\\\\b\\"c\\nd"')
  end
end

RSpec.describe Prouterd::API::RateLimiter do
  it "from_env returns a default-config instance when env is unset" do
    ENV.delete("PROUTERD_WEBHOOK_RATE")
    limiter = described_class.from_env
    expect(limiter.stats("anything")).to eq(0)
  end

  it "from_env parses a MAX/WINDOW spec" do
    ENV["PROUTERD_WEBHOOK_RATE"] = "5/2"
    limiter = described_class.from_env
    # 5 hits should pass, 6th should fail.
    5.times { expect(limiter.allow?("k")).to be(true) }
    expect(limiter.allow?("k")).to be(false)
  ensure
    ENV.delete("PROUTERD_WEBHOOK_RATE")
  end

  it "from_env returns defaults when the env value is malformed" do
    ENV["PROUTERD_WEBHOOK_RATE"] = "bogus"
    limiter = described_class.from_env
    expect(limiter.bucket_count).to eq(0)
  ensure
    ENV.delete("PROUTERD_WEBHOOK_RATE")
  end

  it "allow? trims requests outside the sliding window" do
    limiter = described_class.new(max_requests: 2, window_seconds: 1)
    limiter.allow?("k")
    sleep 1.05
    # After the window, the bucket is trimmed; new requests are accepted.
    expect(limiter.allow?("k")).to be(true)
    expect(limiter.allow?("k")).to be(true)
    expect(limiter.allow?("k")).to be(false)
  end

  it "maybe_evict drops fully-aged-out buckets after the interval" do
    limiter = described_class.new(max_requests: 5, window_seconds: 1)
    limiter.allow?("ghost")
    expect(limiter.bucket_count).to eq(1)

    # Force the next evict pass by walking the clock forward.
    limiter.instance_variable_set(:@last_evict, Time.now.to_f - 120)
    sleep 1.05
    limiter.allow?("anchor") # triggers maybe_evict; ghost should be dropped
    expect(limiter.bucket_count).to eq(1)  # only :anchor left
  end
end

RSpec.describe Prouterd::API::Auth do
  it "returns nil when ?token= sets a non-String form (e.g. token[]=arr)" do
    # Rack parses token[]=x as {"token" => ["x"]} — not a String, so
    # the helper falls through to nil.
    env = { "QUERY_STRING" => "token[]=arr" }
    expect(described_class.token_from(env)).to be_nil
  end
end
