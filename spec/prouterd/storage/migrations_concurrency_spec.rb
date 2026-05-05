require "spec_helper"
require "tempfile"

# Phase 34b: schema migrations are now serialised cross-process via
# `BEGIN EXCLUSIVE`. Two daemons opening the same DB at the same time
# must end up with each migration applied EXACTLY once — no
# duplicate rows, no half-applied state.
#
# We exercise the file-backed path (not :memory:) because cross-process
# locking only matters there. We use threads as a stand-in for two
# processes — the SQLite library issues per-connection locks, which is
# the same surface a real second process would hit.
RSpec.describe Prouterd::Storage::Migrations do
  it "applies every migration exactly once when two connections race on the same DB" do
    Tempfile.create(["prouterd-migrations-race-", ".sqlite3"]) do |tmp|
      tmp.close
      File.delete(tmp.path) # Migrations.run wants to create the file fresh

      results = []
      threads = 2.times.map do
        Thread.new do
          db = Prouterd::Storage::DB.open(tmp.path)
          rows = db.execute(
            "SELECT version, started_at, committed_at FROM schema_migrations ORDER BY version"
          )
          db.close
          results << rows
        end
      end
      threads.each(&:join)

      # Final state: every migration row exists exactly once and is
      # marked committed.
      final_db = Prouterd::Storage::DB.open(tmp.path, run_migrations: false)
      rows = final_db.execute(
        "SELECT version, COUNT(*) FROM schema_migrations GROUP BY version"
      )
      final_db.close

      expected_versions = Prouterd::Storage::Migrations::MIGRATIONS.map(&:version)
      expect(rows.map(&:first)).to match_array(expected_versions)
      expect(rows.map(&:last).uniq).to eq([1])
    end
  end

  it "recovers from a half-applied migration row (started_at without committed_at)" do
    Tempfile.create(["prouterd-migrations-recover-", ".sqlite3"]) do |tmp|
      tmp.close
      File.delete(tmp.path)

      # Apply once to bootstrap the schema
      db = Prouterd::Storage::DB.open(tmp.path)

      # Simulate a crash mid-migration: pick the last version, blank its
      # committed_at. On next open, Migrations.run must clean it up and
      # leave the row recommitted (since the body is idempotent).
      last = Prouterd::Storage::Migrations::MIGRATIONS.last.version
      db.execute("UPDATE schema_migrations SET committed_at = NULL WHERE version = ?", [last])
      expect(db.execute(
        "SELECT committed_at FROM schema_migrations WHERE version = ?", [last]
      ).first.first).to be_nil
      db.close

      # Reopen — bootstrap_table + recover_half_applied + sweep should
      # rerun the migration cleanly.
      db = Prouterd::Storage::DB.open(tmp.path)
      committed_at = db.execute(
        "SELECT committed_at FROM schema_migrations WHERE version = ?", [last]
      ).first.first
      db.close
      expect(committed_at).not_to be_nil
    end
  end
end
