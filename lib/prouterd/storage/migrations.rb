module Prouterd
  module Storage
    # Schema migrations are declared as plain SQL. Each migration has a
    # version string (sortable lexicographically) and a body. The DB runs
    # all unapplied migrations in order on connect.
    #
    # Add new migrations by appending to MIGRATIONS — never edit applied ones.
    module Migrations
      Migration = Struct.new(:version, :description, :up, keyword_init: true)

      MIGRATIONS = [
        Migration.new(
          version: "0001",
          description: "config_commits + config_pointers",
          up: <<~SQL
            CREATE TABLE config_commits (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              checksum TEXT NOT NULL,
              author TEXT,
              message TEXT,
              rendered_config TEXT NOT NULL,
              compiled_config_json TEXT,
              created_at TEXT NOT NULL
            );
            CREATE INDEX idx_config_commits_checksum ON config_commits(checksum);
            CREATE INDEX idx_config_commits_created_at ON config_commits(created_at);

            CREATE TABLE config_pointers (
              name TEXT PRIMARY KEY,
              commit_id INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (commit_id) REFERENCES config_commits(id)
            );
          SQL
        )
      ].freeze

      module_function

      def run(db)
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL
          );
        SQL

        applied = db.execute("SELECT version FROM schema_migrations").map(&:first).to_set

        MIGRATIONS.each do |migration|
          next if applied.include?(migration.version)

          db.transaction do
            db.execute_batch(migration.up)
            db.execute(
              "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
              [migration.version, Time.now.utc.iso8601]
            )
          end
        end
      end
    end
  end
end
