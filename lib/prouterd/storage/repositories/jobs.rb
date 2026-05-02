require "json"
require "time"

module Prouterd
  module Storage
    module Repositories
      # Persistence for the daemon's job queue.
      #
      # Jobs are units of work the worker pool consumes. The full async path
      # (webhook ingestion, /v1 trigger, scheduler tick, /v1 replay) enqueues
      # a job instead of spawning a Thread.new. Workers claim with an atomic
      # UPDATE ... RETURNING, so contention is race-free under SQLite WAL.
      #
      # On daemon restart, locked jobs whose locked_at exceeds a heartbeat
      # threshold get re-queued by Recovery — that's the recovery story for
      # in-flight runs that the previous Phase 8 sweep alone couldn't handle.
      class Jobs
        def initialize(db)
          @db = db
        end

        # Enqueue a unit of work for `run`. `kind` and `payload` let the
        # worker dispatch differently (execute / execute_from_block).
        def enqueue(run_id:, kind: "execute", payload: nil, available_at: nil)
          now = Time.now.utc.iso8601(3)
          available = (available_at || Time.now).utc.iso8601(3)

          @db.execute(
            <<~SQL,
              INSERT INTO jobs
                (run_id, kind, status, attempts, available_at, payload_json, created_at, updated_at)
              VALUES (?, ?, 'queued', 0, ?, ?, ?, ?)
            SQL
            [run_id, kind, available, payload && JSON.dump(payload), now, now]
          )
          get(@db.last_insert_row_id)
        end

        # Atomically claim the next ready job. Returns Job or nil.
        # Uses UPDATE ... RETURNING so two concurrent workers never claim
        # the same row.
        def claim(worker_id)
          now = Time.now.utc.iso8601(3)
          rows = @db.execute(<<~SQL, [worker_id, now, now, now])
            UPDATE jobs
               SET status = 'locked',
                   locked_by = ?,
                   locked_at = ?,
                   attempts = attempts + 1,
                   updated_at = ?
             WHERE id = (
               SELECT id FROM jobs
                WHERE status = 'queued' AND available_at <= ?
                ORDER BY id LIMIT 1
             )
             RETURNING id, run_id, kind, status, attempts, locked_by, locked_at,
                       available_at, payload_json, error_message, created_at, updated_at
          SQL
          row = rows.first
          row && row_to_job(row)
        end

        def complete(id)
          finalize(id, status: "completed")
        end

        def fail(id, error_message)
          finalize(id, status: "failed", error_message: error_message)
        end

        # Requeue a locked job (operator force-retry, or recovery).
        def requeue(id, available_at: nil)
          now = Time.now.utc.iso8601(3)
          available = (available_at || Time.now).utc.iso8601(3)
          @db.execute(
            "UPDATE jobs SET status='queued', locked_by=NULL, locked_at=NULL, available_at=?, updated_at=? WHERE id=?",
            [available, now, id]
          )
        end

        # Recovery: any job stuck in 'locked' longer than threshold is treated
        # as abandoned (the worker that held it died). Returns count + list of
        # affected job ids so the daemon can log clearly.
        def requeue_abandoned(threshold_seconds: 60)
          cutoff = (Time.now - threshold_seconds).utc.iso8601(3)
          rows = @db.execute(
            "SELECT id FROM jobs WHERE status='locked' AND (locked_at IS NULL OR locked_at < ?)",
            [cutoff]
          )
          ids = rows.map(&:first)
          return [] if ids.empty?

          now = Time.now.utc.iso8601(3)
          ids.each do |id|
            @db.execute(
              "UPDATE jobs SET status='queued', locked_by=NULL, locked_at=NULL, available_at=?, updated_at=? WHERE id=?",
              [now, now, id]
            )
          end
          ids
        end

        def get(id)
          row = @db.query_row(
            "SELECT #{columns} FROM jobs WHERE id = ?", [id]
          )
          row && row_to_job(row)
        end

        def stats
          rows = @db.execute("SELECT status, COUNT(*) FROM jobs GROUP BY status")
          rows.each_with_object(Hash.new(0)) { |(s, c), h| h[s] = c }
        end

        def list(status: nil, limit: 100)
          if status
            rows = @db.execute(
              "SELECT #{columns} FROM jobs WHERE status = ? ORDER BY id DESC LIMIT ?",
              [status, limit]
            )
          else
            rows = @db.execute(
              "SELECT #{columns} FROM jobs ORDER BY id DESC LIMIT ?",
              [limit]
            )
          end
          rows.map { |r| row_to_job(r) }
        end

        private

        def finalize(id, status:, error_message: nil)
          now = Time.now.utc.iso8601(3)
          @db.execute(
            "UPDATE jobs SET status=?, error_message=?, locked_by=NULL, locked_at=NULL, updated_at=? WHERE id=?",
            [status, error_message, now, id]
          )
        end

        def columns
          "id, run_id, kind, status, attempts, locked_by, locked_at, " \
            "available_at, payload_json, error_message, created_at, updated_at"
        end

        def row_to_job(r)
          Job.new(
            id: r[0], run_id: r[1], kind: r[2], status: r[3],
            attempts: r[4], locked_by: r[5], locked_at: r[6],
            available_at: r[7], payload_json: r[8], error_message: r[9],
            created_at: r[10], updated_at: r[11]
          )
        end
      end
    end
  end
end
