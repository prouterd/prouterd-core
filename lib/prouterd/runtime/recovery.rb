require "json"
require "time"

module Prouterd
  module Runtime
    # Crash recovery: when a daemon (or shell-driven run) is killed mid-flight,
    # rows are left in `running` / `queued` status forever. On daemon startup
    # we sweep them to a terminal `failed` state with a clear marker so the
    # operator can find and replay them.
    #
    # This is a single-process design: it assumes the daemon is the only
    # writer. If you start two daemons against the same DB, the second one
    # will fail in-flight runs of the first. A heartbeat-based scheme would
    # fix that — Phase 9+ work.
    class Recovery
      ABANDONED_TYPE = "abandoned".freeze
      ABANDONED_REASON = "orchestrator restart — run was in-flight when the previous process exited".freeze
      DEFAULT_LOCK_TIMEOUT = 60

      Result = Struct.new(:runs_swept, :steps_swept, keyword_init: true)

      def self.sweep(db, logger: NullLogger.new, lock_timeout: nil)
        new(db, logger: logger, lock_timeout: lock_timeout).sweep
      end

      def initialize(db, logger: NullLogger.new, lock_timeout: nil)
        @db = db
        @logger = logger
        @lock_timeout = lock_timeout || (ENV["PROUTERD_JOB_LOCK_TIMEOUT"] || DEFAULT_LOCK_TIMEOUT).to_i
      end

      def sweep
        # Order matters: requeue abandoned jobs FIRST so the worker pool
        # can pick them up. Then mark orphaned running runs/steps as failed
        # — those are runs that ran without a job (legacy paths) or whose
        # job is already gone (completed but the run never got finalized,
        # which shouldn't happen but we defend against it anyway).
        jobs = sweep_jobs
        steps = sweep_steps
        runs  = sweep_runs

        if (runs + steps + jobs).positive?
          @logger.info("recovery: swept abandoned state on boot",
                       requeued_jobs: jobs, failed_runs: runs, failed_steps: steps,
                       lock_timeout_s: @lock_timeout)
        end

        Result.new(runs_swept: runs, steps_swept: steps)
      end

      private

      # Locked jobs are the only run/step rows whose run is REALLY still
      # alive — a worker was holding them when the daemon died. Re-queue
      # them so the new worker pool picks them up. Sweep_runs/Sweep_steps
      # below skip rows that have a queued job.
      def sweep_jobs
        repo = Storage::Repositories::Jobs.new(@db)
        ids = repo.requeue_abandoned(threshold_seconds: @lock_timeout)
        ids.length
      rescue SQLite3::SQLException
        # jobs table may not exist on a pre-Phase-11 DB; not fatal.
        0
      end

      def sweep_steps
        # Skip steps whose run has a live job — the worker pool will run
        # them again. We just nuke truly orphaned ones.
        rows = @db.execute(<<~SQL)
          SELECT s.id FROM run_steps s
          WHERE s.status IN ('queued', 'running', 'retrying')
            AND NOT EXISTS (
              SELECT 1 FROM jobs j WHERE j.run_id = s.run_id AND j.status IN ('queued', 'locked')
            )
        SQL
        return 0 if rows.empty?

        ids = rows.map(&:first)
        finished_at = Time.now.utc.iso8601(3)
        ids.each do |id|
          @db.execute(
            "UPDATE run_steps SET status = ?, error_type = ?, error_message = ?, finished_at = ? WHERE id = ?",
            ["failed", ABANDONED_TYPE, ABANDONED_REASON, finished_at, id]
          )
        end
        ids.length
      rescue SQLite3::SQLException
        # jobs table may not exist on a pre-Phase-11 DB. Fall back to the
        # original behavior: sweep everything in the indeterminate states.
        sweep_steps_no_jobs_table
      end

      def sweep_runs
        rows = @db.execute(<<~SQL)
          SELECT r.id FROM runs r
          WHERE r.status IN ('queued', 'running')
            AND NOT EXISTS (
              SELECT 1 FROM jobs j WHERE j.run_id = r.id AND j.status IN ('queued', 'locked')
            )
        SQL
        return 0 if rows.empty?

        ids = rows.map(&:first)
        finished_at = Time.now.utc.iso8601(3)
        ids.each do |id|
          @db.execute(
            "UPDATE runs SET status = ?, error_summary = ?, finished_at = ? WHERE id = ?",
            ["failed", ABANDONED_REASON, finished_at, id]
          )
        end
        ids.length
      rescue SQLite3::SQLException
        sweep_runs_no_jobs_table
      end

      def sweep_steps_no_jobs_table
        rows = @db.execute(
          "SELECT id FROM run_steps WHERE status IN ('queued', 'running', 'retrying')"
        )
        return 0 if rows.empty?

        ids = rows.map(&:first)
        finished_at = Time.now.utc.iso8601(3)
        ids.each do |id|
          @db.execute(
            "UPDATE run_steps SET status = ?, error_type = ?, error_message = ?, finished_at = ? WHERE id = ?",
            ["failed", ABANDONED_TYPE, ABANDONED_REASON, finished_at, id]
          )
        end
        ids.length
      end

      def sweep_runs_no_jobs_table
        rows = @db.execute(
          "SELECT id FROM runs WHERE status IN ('queued', 'running')"
        )
        return 0 if rows.empty?

        ids = rows.map(&:first)
        finished_at = Time.now.utc.iso8601(3)
        ids.each do |id|
          @db.execute(
            "UPDATE runs SET status = ?, error_summary = ?, finished_at = ? WHERE id = ?",
            ["failed", ABANDONED_REASON, finished_at, id]
          )
        end
        ids.length
      end
    end
  end
end
