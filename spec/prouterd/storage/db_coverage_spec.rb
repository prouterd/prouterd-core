require "spec_helper"

RSpec.describe Prouterd::Storage::DB do
  describe ".open(:memory:)" do
    it "skips the WAL pragma for in-memory databases" do
      # If WAL were attempted on :memory: it would raise.
      expect { described_class.open(":memory:") }.not_to raise_error
    end
  end

  describe "#closed?" do
    it "returns false on an open DB and true after close" do
      db = described_class.open(":memory:")
      expect(db.closed?).to be(false)
      db.close
      expect(db.closed?).to be(true)
    end
  end

  describe "#close" do
    it "is safe to call twice (`&.` else branch)" do
      db = described_class.open(":memory:")
      db.close
      expect { db.close }.not_to raise_error
    end
  end

  describe "#execute disk-unavailable translation" do
    let(:db) { described_class.open(":memory:") }
    after { db.close rescue nil }

    it "wraps SQLite3::IOException raised mid-execute as DiskUnavailableError" do
      sqlite = db.instance_variable_get(:@sqlite)
      allow(sqlite).to receive(:execute).and_raise(SQLite3::IOException, "disk I/O error")
      expect {
        db.execute("SELECT 1")
      }.to raise_error(Prouterd::Storage::DiskUnavailableError, /storage write failed.*IOException/)
    end

    it "wraps disk-full errors in execute_batch too" do
      sqlite = db.instance_variable_get(:@sqlite)
      allow(sqlite).to receive(:execute_batch).and_raise(SQLite3::FullException, "no space")
      expect {
        db.execute_batch("SELECT 1; SELECT 2;")
      }.to raise_error(Prouterd::Storage::DiskUnavailableError, /FullException/)
    end
  end

  describe "#healthy?" do
    let(:db) { described_class.open(":memory:") }
    after { db.close rescue nil }

    it "returns true on a working DB" do
      expect(db.healthy?).to be(true)
    end

    it "returns false when SQLite raises a disk-unavailable exception" do
      sqlite = db.instance_variable_get(:@sqlite)
      allow(sqlite).to receive(:execute).and_call_original
      allow(sqlite).to receive(:execute).with("SELECT 1")
        .and_raise(SQLite3::IOException, "disk I/O error")
      expect(db.healthy?).to be(false)
    end

    it "returns true when SQLite raises a BUSY exception (contention is still 'healthy')" do
      sqlite = db.instance_variable_get(:@sqlite)
      allow(sqlite).to receive(:execute).and_call_original
      allow(sqlite).to receive(:execute).with("SELECT 1")
        .and_raise(SQLite3::BusyException, "database is locked")
      expect(db.healthy?).to be(true)
    end
  end
end
