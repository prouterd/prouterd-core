# frozen_string_literal: true

require "time"

module Prouterd
  module Runtime
    # Tiny mixin: append a system-stream log line for a run + publish
    # the matching `:log_appended` event in one call. Used both at the
    # run level (Orchestrator boundary events: cross-block-retry trigger,
    # cancel, recovery) and at the block level (BlockExecutor's
    # FanOut warning paths).
    #
    # Hosts must expose `@runs` (Storage::Repositories::Runs) and
    # `@events` (event bus with `publish(topic, **payload)`).
    module SystemLog
      def log_system_safe(run, message, db_mutex)
        db_mutex.synchronize { @runs.append_log(run_id: run.id, stream: "system", content: message) }
        @events.publish(:log_appended,
                        run_id:     run.id,
                        run_uid:    run.uid,
                        step_id:    nil,
                        stream:     "system",
                        content:    message,
                        created_at: Time.now.utc.iso8601(3))
      end
    end
  end
end
