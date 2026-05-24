require "spec_helper"

RSpec.describe Prouterd::Events do
  subject(:bus) { described_class.new }

  describe "#subscribe / #publish" do
    it "delivers the payload to subscribers of the matching topic" do
      received = []
      bus.subscribe(:run_updated) { |topic, payload| received << [topic, payload] }

      bus.publish(:run_updated, run_uid: "run_42", status: "success")

      expect(received).to eq([[:run_updated, { run_uid: "run_42", status: "success" }]])
    end

    it "does not deliver across topics" do
      to_a = []
      to_b = []
      bus.subscribe(:a) { |_, p| to_a << p }
      bus.subscribe(:b) { |_, p| to_b << p }

      bus.publish(:a, :alpha)

      expect(to_a).to eq([:alpha])
      expect(to_b).to be_empty
    end

    it "delivers to multiple subscribers on the same topic" do
      a = b = nil
      bus.subscribe(:t) { |_, p| a = p }
      bus.subscribe(:t) { |_, p| b = p }

      bus.publish(:t, 99)

      expect(a).to eq(99)
      expect(b).to eq(99)
    end

    it "isolates subscriber failures so others still receive the event" do
      delivered = 0
      bus.subscribe(:t) { raise "boom" }
      bus.subscribe(:t) { delivered += 1 }

      expect { bus.publish(:t, :p) }.not_to raise_error
      expect(delivered).to eq(1)
    end

    it "raises if no block given to subscribe" do
      expect { bus.subscribe(:t) }.to raise_error(ArgumentError)
    end
  end

  describe "#unsubscribe" do
    it "stops delivery to the unsubscribed handle" do
      delivered = 0
      handle = bus.subscribe(:t) { delivered += 1 }

      bus.publish(:t, 1)
      bus.unsubscribe(handle)
      bus.publish(:t, 2)

      expect(delivered).to eq(1)
    end

    it "is a no-op for nil handles" do
      expect { bus.unsubscribe(nil) }.not_to raise_error
    end

    it "keeps the topic bucket when other subscribers remain" do
      h1 = bus.subscribe(:t) { }
      _h2 = bus.subscribe(:t) { }
      bus.unsubscribe(h1)
      expect(bus.has_subscribers?(:t)).to be(true)
      expect(bus.subscribers_count(:t)).to eq(1)
    end
  end

  describe "#has_subscribers? / #subscribers_count" do
    it "tracks subscriber registration / removal" do
      expect(bus.has_subscribers?(:t)).to be false
      handle = bus.subscribe(:t) { }
      expect(bus.has_subscribers?(:t)).to be true
      expect(bus.subscribers_count(:t)).to eq(1)
      bus.unsubscribe(handle)
      expect(bus.has_subscribers?(:t)).to be false
    end
  end

  describe "the process-wide singleton" do
    after { described_class::DEFAULT.clear }

    it "round-trips publish/subscribe via class-level helpers" do
      received = []
      described_class.subscribe(:x) { |_, p| received << p }
      described_class.publish(:x, 7)
      expect(received).to eq([7])
    end

    it "is the same instance returned by .default" do
      expect(described_class.default).to be(described_class::DEFAULT)
    end

    it ".unsubscribe delegates to DEFAULT" do
      seen = []
      handle = described_class.subscribe(:t) { |_, p| seen << p }
      described_class.publish(:t, 1)
      described_class.unsubscribe(handle)
      described_class.publish(:t, 2)
      expect(seen).to eq([1])
    end
  end

  describe "topics + clear" do
    it "topics lists the currently-subscribed topic symbols" do
      bus.subscribe(:a) { }
      bus.subscribe(:b) { }
      expect(bus.topics).to contain_exactly(:a, :b)
    end

    it "clear removes every subscription" do
      bus.subscribe(:a) { }
      bus.clear
      expect(bus.topics).to eq([])
    end

    it "unsubscribing the last subscriber drops the topic key" do
      handle = bus.subscribe(:vanishing) { }
      expect(bus.topics).to include(:vanishing)
      bus.unsubscribe(handle)
      expect(bus.topics).not_to include(:vanishing)
    end

    it "unsubscribe with an unknown topic / handle is a no-op" do
      expect { bus.unsubscribe([:nonexistent_topic, 12345]) }.not_to raise_error
    end
  end
end
