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
        ),
        Migration.new(
          version: "0002",
          description: "runtime: runs, run_steps, run_logs, artifacts",
          up: <<~SQL
            CREATE TABLE runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uid TEXT NOT NULL UNIQUE,
              process_name TEXT NOT NULL,
              process_config_commit_id INTEGER,
              interface_name TEXT,
              status TEXT NOT NULL,
              input_event_json TEXT,
              context_json TEXT,
              error_summary TEXT,
              started_at TEXT,
              finished_at TEXT,
              created_at TEXT NOT NULL,
              parent_run_id INTEGER,
              replay_of_run_id INTEGER,
              FOREIGN KEY (process_config_commit_id) REFERENCES config_commits(id),
              FOREIGN KEY (parent_run_id) REFERENCES runs(id),
              FOREIGN KEY (replay_of_run_id) REFERENCES runs(id)
            );
            CREATE INDEX idx_runs_status ON runs(status);
            CREATE INDEX idx_runs_process ON runs(process_name);
            CREATE INDEX idx_runs_uid ON runs(uid);
            CREATE INDEX idx_runs_created_at ON runs(created_at);

            CREATE TABLE run_steps (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL,
              block_name TEXT NOT NULL,
              status TEXT NOT NULL,
              attempt INTEGER NOT NULL DEFAULT 1,
              image TEXT,
              input_json TEXT,
              output_json TEXT,
              exit_code INTEGER,
              error_type TEXT,
              error_message TEXT,
              started_at TEXT,
              finished_at TEXT,
              duration_ms INTEGER,
              created_at TEXT NOT NULL,
              FOREIGN KEY (run_id) REFERENCES runs(id)
            );
            CREATE INDEX idx_run_steps_run ON run_steps(run_id);
            CREATE INDEX idx_run_steps_status ON run_steps(status);

            CREATE TABLE run_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL,
              step_id INTEGER,
              stream TEXT NOT NULL,
              content TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (run_id) REFERENCES runs(id),
              FOREIGN KEY (step_id) REFERENCES run_steps(id)
            );
            CREATE INDEX idx_run_logs_run ON run_logs(run_id);
            CREATE INDEX idx_run_logs_step ON run_logs(step_id);

            CREATE TABLE artifacts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL,
              step_id INTEGER NOT NULL,
              block_name TEXT NOT NULL,
              name TEXT NOT NULL,
              path TEXT NOT NULL,
              content_type TEXT,
              size_bytes INTEGER NOT NULL,
              checksum TEXT,
              created_at TEXT NOT NULL,
              FOREIGN KEY (run_id) REFERENCES runs(id),
              FOREIGN KEY (step_id) REFERENCES run_steps(id)
            );
            CREATE INDEX idx_artifacts_run ON artifacts(run_id);
            CREATE INDEX idx_artifacts_step ON artifacts(step_id);
          SQL
        ),
        Migration.new(
          version: "0003",
          description: "jobs queue for daemon worker pool",
          up: <<~SQL
            CREATE TABLE jobs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL,
              kind TEXT NOT NULL DEFAULT 'execute',
              status TEXT NOT NULL DEFAULT 'queued',
              attempts INTEGER NOT NULL DEFAULT 0,
              locked_by TEXT,
              locked_at TEXT,
              available_at TEXT NOT NULL,
              payload_json TEXT,
              error_message TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              FOREIGN KEY (run_id) REFERENCES runs(id)
            );
            CREATE INDEX idx_jobs_status_available ON jobs(status, available_at);
            CREATE INDEX idx_jobs_run ON jobs(run_id);
            CREATE INDEX idx_jobs_locked_at ON jobs(locked_at);
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
