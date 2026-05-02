require "spec_helper"

RSpec.describe Prouterd::Runtime::RetryCalculator do
  def policy(attempts:, backoff:, initial: 1000, max: nil)
    p = Prouterd::Config::AST::Policy.new(name: "p", line: 0)
    p.retry_attempts = attempts
    p.retry_backoff = backoff
    p.retry_initial_delay_ms = initial
    p.retry_max_delay_ms = max
    p
  end

  describe ".delay_ms_before" do
    it "returns 0 for the first attempt" do
      expect(described_class.delay_ms_before(policy(attempts: 3, backoff: "exponential"), 1)).to eq(0)
    end

    it "is constant for fixed backoff" do
      pol = policy(attempts: 3, backoff: "fixed", initial: 500)
      expect(described_class.delay_ms_before(pol, 2)).to eq(500)
      expect(described_class.delay_ms_before(pol, 3)).to eq(500)
    end

    it "doubles for exponential backoff" do
      pol = policy(attempts: 4, backoff: "exponential", initial: 1000)
      expect(described_class.delay_ms_before(pol, 2)).to eq(1000)
      expect(described_class.delay_ms_before(pol, 3)).to eq(2000)
      expect(described_class.delay_ms_before(pol, 4)).to eq(4000)
    end

    it "caps at max_delay" do
      pol = policy(attempts: 5, backoff: "exponential", initial: 1000, max: 2500)
      expect(described_class.delay_ms_before(pol, 2)).to eq(1000)
      expect(described_class.delay_ms_before(pol, 3)).to eq(2000)
      expect(described_class.delay_ms_before(pol, 4)).to eq(2500)
      expect(described_class.delay_ms_before(pol, 5)).to eq(2500)
    end

    it "scales linearly for linear backoff" do
      pol = policy(attempts: 4, backoff: "linear", initial: 1000)
      expect(described_class.delay_ms_before(pol, 2)).to eq(1000)
      expect(described_class.delay_ms_before(pol, 3)).to eq(2000)
      expect(described_class.delay_ms_before(pol, 4)).to eq(3000)
    end
  end

  describe ".more_attempts?" do
    it "is false when attempt has reached the limit" do
      pol = policy(attempts: 3, backoff: "fixed")
      expect(described_class.more_attempts?(pol, 3)).to be(false)
      expect(described_class.more_attempts?(pol, 2)).to be(true)
    end

    it "is false when policy is nil (no retries)" do
      expect(described_class.more_attempts?(nil, 1)).to be(false)
    end

    it "is false when retry_attempts is unset" do
      pol = Prouterd::Config::AST::Policy.new(name: "p", line: 0)
      expect(described_class.more_attempts?(pol, 1)).to be(false)
    end
  end
end
