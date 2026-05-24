require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Storage::Migrations do
  describe ".run idempotency on a freshly-opened DB" do
    it "re-opening triggers the cols-already-exist branches in 0004/0005/0006/0007" do
      Tempfile.create(["prouterd-mig-idem-", ".sqlite3"]) do |tmp|
        tmp.close
        File.delete(tmp.path)

        db1 = Prouterd::Storage::DB.open(tmp.path)
        before = db1.execute("SELECT version FROM schema_migrations ORDER BY version").map(&:first)
        db1.close

        # Re-open: every migration is already applied, but the bootstrap-table
        # logic still runs and the PRAGMA-table-info branch fires for each
        # ALTER-TABLE-style migration.
        db2 = Prouterd::Storage::DB.open(tmp.path)
        after = db2.execute("SELECT version FROM schema_migrations ORDER BY version").map(&:first)
        db2.close
        expect(after).to eq(before)
      end
    end

    it "queryable applied versions equal the declared MIGRATIONS list" do
      db = Prouterd::Storage::DB.open(":memory:")
      versions = db.execute("SELECT version FROM schema_migrations ORDER BY version").map(&:first)
      expect(versions).to eq(described_class::MIGRATIONS.map(&:version))
      db.close
    end

    it "re-runs each ALTER-style migration with the column already present (else branch on 0004-0007)" do
      Tempfile.create(["prouterd-mig-recover-all-", ".sqlite3"]) do |tmp|
        tmp.close
        File.delete(tmp.path)

        db = Prouterd::Storage::DB.open(tmp.path)
        # Wipe committed_at on the ALTER-style migrations so recover_half_applied
        # deletes their rows and the next open re-runs each body. With columns
        # still present, the `unless cols.include?("X")` else branch fires.
        %w[0004 0005 0006 0007].each do |v|
          db.execute("UPDATE schema_migrations SET committed_at = NULL WHERE version = ?", [v])
        end
        db.close

        db2 = Prouterd::Storage::DB.open(tmp.path)
        committed = db2.execute(
          "SELECT version, committed_at FROM schema_migrations ORDER BY version"
        ).to_h
        %w[0004 0005 0006 0007].each do |v|
          expect(committed[v]).not_to be_nil
        end
        db2.close
      end
    end
  end

  describe ".with_exclusive_lock" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    after { db.close }

    it "calls ROLLBACK and re-raises when the block raises" do
      expect(db).to receive(:execute).with("BEGIN EXCLUSIVE").and_call_original
      expect(db).to receive(:execute).with("ROLLBACK").and_call_original
      expect {
        described_class.with_exclusive_lock(db) { raise "boom" }
      }.to raise_error("boom")
    end

    it "retries on SQLite3::BusyException and eventually succeeds" do
      stub_const("Prouterd::Storage::Migrations::LOCK_RETRY_BACKOFF_SECONDS", 0.001)
      stub_const("Prouterd::Storage::Migrations::LOCK_RETRY_DEADLINE_SECONDS", 5)

      attempts = 0
      original = db.method(:execute)
      allow(db).to receive(:execute) do |sql, *rest|
        if sql == "BEGIN EXCLUSIVE"
          attempts += 1
          raise SQLite3::BusyException, "database is locked" if attempts == 1

          original.call(sql, *rest)
        else
          original.call(sql, *rest)
        end
      end

      called = false
      described_class.with_exclusive_lock(db) { called = true }
      expect(called).to be(true)
      expect(attempts).to be >= 2
    end

    it "raises StorageError after the deadline expires while BUSY" do
      stub_const("Prouterd::Storage::Migrations::LOCK_RETRY_BACKOFF_SECONDS", 0.001)
      stub_const("Prouterd::Storage::Migrations::LOCK_RETRY_DEADLINE_SECONDS", 0.01)

      allow(db).to receive(:execute).with("BEGIN EXCLUSIVE")
        .and_raise(SQLite3::BusyException, "database is locked")

      expect {
        described_class.with_exclusive_lock(db) { :unreachable }
      }.to raise_error(Prouterd::Storage::StorageError, /migration lock unavailable/)
    end
  end
end
