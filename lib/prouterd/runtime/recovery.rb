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

      Result = Struct.new(:runs_swept, :steps_swept, keyword_init: true)

      def self.sweep(db, output: nil)
        new(db, output).sweep
      end

      def initialize(db, output = nil)
        @db = db
        @output = output
      end

      def sweep
        steps = sweep_steps
        runs  = sweep_runs

        @output&.puts("recovery: marked #{runs} run(s) and #{steps} step(s) as failed (abandoned)") if (runs + steps).positive?

        Result.new(runs_swept: runs, steps_swept: steps)
      end

      private

      def sweep_steps
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

      def sweep_runs
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
