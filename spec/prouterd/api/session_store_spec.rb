require "spec_helper"

RSpec.describe Prouterd::API::SessionStore do
  it "creates a fresh hex session id and accepts it back" do
    s = described_class.new
    sid = s.create
    expect(sid).to match(/\A[0-9a-f]{64}\z/)
    expect(s.valid?(sid)).to be(true)
  end

  it "rejects an unknown session id" do
    s = described_class.new
    expect(s.valid?("nope")).to be(false)
    expect(s.valid?(nil)).to be(false)
    expect(s.valid?("")).to be(false)
  end

  it "expires sessions after the TTL" do
    now = Time.now
    clock_value = now
    s = described_class.new(ttl: 60, clock: -> { clock_value })
    sid = s.create
    expect(s.valid?(sid)).to be(true)

    clock_value = now + 30           # within window — fine
    expect(s.valid?(sid)).to be(true)

    clock_value = now + 1000         # well past TTL since last touch
    expect(s.valid?(sid)).to be(false)
  end

  it "refreshes last_seen_at on each successful check (sliding window)" do
    now = Time.now
    clock_value = now
    s = described_class.new(ttl: 60, clock: -> { clock_value })
    sid = s.create

    clock_value = now + 50
    expect(s.valid?(sid)).to be(true)   # touched, last_seen_at = now+50
    clock_value = now + 100             # 50s since touch — still alive
    expect(s.valid?(sid)).to be(true)
  end

  it "revokes a session" do
    s = described_class.new
    sid = s.create
    s.revoke(sid)
    expect(s.valid?(sid)).to be(false)
  end

  it "size sweeps expired entries" do
    now = Time.now
    clock_value = now
    s = described_class.new(ttl: 10, clock: -> { clock_value })
    sid1 = s.create
    sid2 = s.create
    expect(s.size).to eq(2)

    clock_value = now + 100
    expect(s.size).to eq(0)
    expect(s.valid?(sid1)).to be(false)
    expect(s.valid?(sid2)).to be(false)
  end
end
