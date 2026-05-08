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
            CREATE TABLE IF NOT EXISTS config_commits (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              checksum TEXT NOT NULL,
              author TEXT,
              message TEXT,
              rendered_config TEXT NOT NULL,
              compiled_config_json TEXT,
              created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_config_commits_checksum ON config_commits(checksum);
            CREATE INDEX IF NOT EXISTS idx_config_commits_created_at ON config_commits(created_at);

            CREATE TABLE IF NOT EXISTS config_pointers (
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
            CREATE TABLE IF NOT EXISTS runs (
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
            CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
            CREATE INDEX IF NOT EXISTS idx_runs_process ON runs(process_name);
            CREATE INDEX IF NOT EXISTS idx_runs_uid ON runs(uid);
            CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at);

            CREATE TABLE IF NOT EXISTS run_steps (
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
            CREATE INDEX IF NOT EXISTS idx_run_steps_run ON run_steps(run_id);
            CREATE INDEX IF NOT EXISTS idx_run_steps_status ON run_steps(status);

            CREATE TABLE IF NOT EXISTS run_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              run_id INTEGER NOT NULL,
              step_id INTEGER,
              stream TEXT NOT NULL,
              content TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (run_id) REFERENCES runs(id),
              FOREIGN KEY (step_id) REFERENCES run_steps(id)
            );
            CREATE INDEX IF NOT EXISTS idx_run_logs_run ON run_logs(run_id);
            CREATE INDEX IF NOT EXISTS idx_run_logs_step ON run_logs(step_id);

            CREATE TABLE IF NOT EXISTS artifacts (
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
            CREATE INDEX IF NOT EXISTS idx_artifacts_run ON artifacts(run_id);
            CREATE INDEX IF NOT EXISTS idx_artifacts_step ON artifacts(step_id);
          SQL
        ),
        Migration.new(
          version: "0003",
          description: "jobs queue for daemon worker pool",
          up: <<~SQL
            CREATE TABLE IF NOT EXISTS jobs (
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
            CREATE INDEX IF NOT EXISTS idx_jobs_status_available ON jobs(status, available_at);
            CREATE INDEX IF NOT EXISTS idx_jobs_run ON jobs(run_id);
            CREATE INDEX IF NOT EXISTS idx_jobs_locked_at ON jobs(locked_at);
          SQL
        ),
        Migration.new(
          version: "0004",
          description: "runs.thread_id for per-entity scoping",
          # SQLite has no `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, so
          # a half-applied retry would otherwise hit "duplicate column"
          # — we inspect PRAGMA table_info first to keep this idempotent.
          up: lambda do |db|
            cols = db.execute("PRAGMA table_info(runs)").map { |row| row[1] }
            db.execute("ALTER TABLE runs ADD COLUMN thread_id TEXT") unless cols.include?("thread_id")
            db.execute_batch(<<~SQL)
              CREATE INDEX IF NOT EXISTS idx_runs_process_thread
                ON runs(process_name, thread_id);
              CREATE INDEX IF NOT EXISTS idx_runs_thread ON runs(thread_id);
            SQL
          end
        ),
        Migration.new(
          version: "0005",
          description: "runs.tokens_in / runs.tokens_out for per-run LLM usage",
          up: lambda do |db|
            cols = db.execute("PRAGMA table_info(runs)").map { |row| row[1] }
            unless cols.include?("tokens_in")
              db.execute("ALTER TABLE runs ADD COLUMN tokens_in INTEGER NOT NULL DEFAULT 0")
            end
            unless cols.include?("tokens_out")
              db.execute("ALTER TABLE runs ADD COLUMN tokens_out INTEGER NOT NULL DEFAULT 0")
            end
          end
        ),
        Migration.new(
          version: "0006",
          description: "runs.cost_usd for per-run LLM USD accumulator",
          up: lambda do |db|
            cols = db.execute("PRAGMA table_info(runs)").map { |row| row[1] }
            unless cols.include?("cost_usd")
              db.execute("ALTER TABLE runs ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0.0")
            end
          end
        )
      ].freeze

      module_function

      # Acquire a process-wide exclusive write lock on SQLite for the
      # migration sweep. Two daemons that race on startup must not both
      # try to apply migrations concurrently — `BEGIN EXCLUSIVE` is the
      # SQLite-native serialisation primitive. Bounded retry covers the
      # case where the other process is mid-sweep.
      LOCK_RETRY_DEADLINE_SECONDS = 30
      LOCK_RETRY_BACKOFF_SECONDS = 0.1

      def run(db)
        # Run the entire boot sequence under one exclusive lock. Without
        # this, a second concurrent connection can race on bootstrap
        # (CREATE TABLE schema_migrations) or on recover_half_applied
        # while the first holds an exclusive transaction for the sweep.
        # Migration bodies are written idempotently (CREATE TABLE IF
        # NOT EXISTS) so re-running a half-applied migration is safe.
        with_exclusive_lock(db) do
          bootstrap_table(db)
          recover_half_applied(db)

          applied = db.execute("SELECT version FROM schema_migrations WHERE committed_at IS NOT NULL")
                      .map(&:first).to_set

          MIGRATIONS.each do |migration|
            next if applied.include?(migration.version)

            now = Time.now.utc.iso8601
            db.execute(
              "INSERT INTO schema_migrations (version, applied_at, started_at) VALUES (?, ?, ?)",
              [migration.version, now, now]
            )
            apply_migration_body(db, migration)
            db.execute(
              "UPDATE schema_migrations SET committed_at = ? WHERE version = ?",
              [Time.now.utc.iso8601, migration.version]
            )
          end
        end
      end

      # A migration body is either a SQL string (the common case) or a
      # Proc that takes the db and runs whatever idempotent bootstrap it
      # needs. Procs are required when a single migration must inspect
      # current state to stay re-runnable (e.g. ALTER TABLE ADD COLUMN,
      # which SQLite has no `IF NOT EXISTS` form for).
      def apply_migration_body(db, migration)
        case migration.up
        when Proc
          migration.up.call(db)
        else
          db.execute_batch(migration.up.to_s)
        end
      end

      def bootstrap_table(db)
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL
          );
        SQL

        # Idempotent ALTER — older databases get the new columns added.
        # `started_at` mirrors `applied_at` for legacy rows; `committed_at`
        # backfills NULL → existing rows are inferred-completed via the
        # backfill below.
        existing = db.execute("PRAGMA table_info(schema_migrations)").map { |row| row[1] }
        unless existing.include?("started_at")
          db.execute("ALTER TABLE schema_migrations ADD COLUMN started_at TEXT")
        end
        unless existing.include?("committed_at")
          db.execute("ALTER TABLE schema_migrations ADD COLUMN committed_at TEXT")
          # Pre-existing rows count as committed — they were applied fully
          # under the old code path which only inserted on success.
          db.execute("UPDATE schema_migrations SET committed_at = applied_at WHERE committed_at IS NULL")
        end
      end

      # Drop any row where `started_at` is set but `committed_at` is not —
      # that's a half-applied migration from a crashed prior boot. With
      # the row gone, the migration is reapplied this boot. The migration
      # body must therefore be idempotent (use IF NOT EXISTS / similar).
      def recover_half_applied(db)
        db.execute(
          "DELETE FROM schema_migrations WHERE started_at IS NOT NULL AND committed_at IS NULL"
        )
      end

      def with_exclusive_lock(db)
        deadline = Time.now + LOCK_RETRY_DEADLINE_SECONDS
        loop do
          begin
            db.execute("BEGIN EXCLUSIVE")
            break
          rescue SQLite3::BusyException
            raise StorageError, "migration lock unavailable for >#{LOCK_RETRY_DEADLINE_SECONDS}s" if Time.now > deadline

            sleep LOCK_RETRY_BACKOFF_SECONDS
          end
        end

        begin
          yield
          db.execute("COMMIT")
        rescue StandardError
          db.execute("ROLLBACK") rescue nil
          raise
        end
      end
    end
  end
end
