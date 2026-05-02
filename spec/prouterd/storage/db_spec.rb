require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Storage::DB do
  it "opens an in-memory DB and runs migrations" do
    db = described_class.open(":memory:")
    rows = db.execute("SELECT version FROM schema_migrations").map(&:first)
    expect(rows).not_to be_empty
    db.close
  end

  it "creates parent directories for relative paths" do
    Dir.mktmpdir("prouterd-db-test-") do |dir|
      path = File.join(dir, "nested", "subdir", "test.db")
      db = described_class.open(path)
      expect(File.exist?(path)).to be(true)
      db.close
    end
  end

  it "is idempotent — opening a DB twice does not re-apply migrations" do
    Tempfile.create(["prouterd-db-idem-", ".sqlite3"]) do |tmp|
      tmp.close
      db1 = described_class.open(tmp.path)
      first_count = db1.execute("SELECT COUNT(*) FROM schema_migrations").first.first
      db1.close

      db2 = described_class.open(tmp.path)
      second_count = db2.execute("SELECT COUNT(*) FROM schema_migrations").first.first
      db2.close

      expect(first_count).to eq(second_count)
    end
  end

  it "creates expected tables" do
    db = described_class.open(":memory:")
    table_names = db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").map(&:first)
    expect(table_names).to include("config_commits", "config_pointers", "schema_migrations")
    db.close
  end

  it "supports nested transactions safely" do
    db = described_class.open(":memory:")
    db.transaction do
      db.transaction do
        db.execute("INSERT INTO config_commits (checksum, rendered_config, created_at) VALUES (?, ?, ?)",
                   ["abc", "router x\nexit", "2026-01-01"])
      end
    end
    expect(db.execute("SELECT COUNT(*) FROM config_commits").first.first).to eq(1)
    db.close
  end
end
