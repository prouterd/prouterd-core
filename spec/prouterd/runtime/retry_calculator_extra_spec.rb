require "spec_helper"

# Coverage gap: the existing retry_calculator_spec covers happy paths
# of every backoff type. These exercise the early-exit branches
# (nil policy, no attempts cap, the case-`else` safety) plus the
# `max` cap when omitted.
RSpec.describe Prouterd::Runtime::RetryCalculator do
  Policy = Prouterd::Config::AST::Policy

  it "delay_ms_before returns 0 for the first attempt" do
    p = Policy.new(name: "p", line: 1)
    p.retry_initial_delay_ms = 500
    p.retry_backoff = "fixed"
    expect(described_class.delay_ms_before(p, 1)).to eq(0)
  end

  it "delay_ms_before treats nil retry_backoff as fixed" do
    p = Policy.new(name: "p", line: 1)
    p.retry_initial_delay_ms = 200
    p.retry_backoff = nil
    expect(described_class.delay_ms_before(p, 3)).to eq(200)
  end

  it "delay_ms_before with an unknown retry_backoff falls back to initial" do
    p = Policy.new(name: "p", line: 1)
    p.retry_initial_delay_ms = 750
    # Validator usually rejects this, but the calculator's safety
    # branch keeps it defined-behaviour rather than nil-deref'ing
    # the next attempt's delay.
    p.retry_backoff = "weirdo"
    expect(described_class.delay_ms_before(p, 4)).to eq(750)
  end

  it "delay_ms_before returns the raw value when no max is set" do
    p = Policy.new(name: "p", line: 1)
    p.retry_initial_delay_ms = 100
    p.retry_backoff = "exponential"
    p.retry_max_delay_ms = nil
    # attempt 5 → 100 * 2^3 = 800; no cap.
    expect(described_class.delay_ms_before(p, 5)).to eq(800)
  end

  it "more_attempts? returns false for a nil policy" do
    expect(described_class.more_attempts?(nil, 0)).to be(false)
  end

  it "more_attempts? returns false when policy has no retry_attempts" do
    p = Policy.new(name: "p", line: 1)
    p.retry_attempts = nil
    expect(described_class.more_attempts?(p, 0)).to be(false)
  end

  it "more_attempts? compares strictly less than retry_attempts" do
    p = Policy.new(name: "p", line: 1)
    p.retry_attempts = 3
    expect(described_class.more_attempts?(p, 2)).to be(true)
    expect(described_class.more_attempts?(p, 3)).to be(false)
  end
end
