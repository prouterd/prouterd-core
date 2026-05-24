require "spec_helper"

# Tiny coverage specs for the Struct-shaped data classes in
# lib/prouterd/storage. The shapes are exercised end-to-end through
# the runs / configs / jobs repository specs; this file just nails
# the conditional branches inside the Struct's instance methods.
RSpec.describe Prouterd::Storage do
  describe Prouterd::Storage::Commit do
    it "short_checksum truncates a checksum to 12 chars" do
      c = described_class.new(checksum: "a" * 40)
      expect(c.short_checksum).to eq("a" * 12)
    end

    it "short_checksum returns nil when no checksum is set" do
      c = described_class.new(checksum: nil)
      expect(c.short_checksum).to be_nil
    end
  end

  describe Prouterd::Storage::Job do
    it "payload parses JSON when payload_json is present" do
      j = described_class.new(payload_json: '{"key":"value"}')
      expect(j.payload).to eq("key" => "value")
    end

    it "payload returns {} when payload_json is nil" do
      expect(described_class.new(payload_json: nil).payload).to eq({})
    end

    it "payload returns {} when payload_json is the empty string" do
      expect(described_class.new(payload_json: "").payload).to eq({})
    end
  end
end
