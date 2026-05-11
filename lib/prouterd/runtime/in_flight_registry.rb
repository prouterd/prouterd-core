# frozen_string_literal: true

module Prouterd
  module Runtime
    # Thread-safe map of in-flight runs to the resources currently driving them.
    #
    # Two callers register here:
    #   * The orchestrator registers a run when execute() starts and
    #     unregisters when it returns. This lets the daemon count active
    #     runs (graceful shutdown) and observe queue depth (metrics).
    #   * DockerRunner registers a (run_uid, container_id) pair AFTER
    #     container.start and removes it in the cleanup ensure-block.
    #     This lets `cancel run` issue a real `docker kill` against the
    #     in-flight container instead of waiting for it to finish naturally.
    #
    # All operations are constant-time, guarded by a single mutex. The
    # registry is per-process; multi-daemon deployments (not supported in
    # v0.1) would need a DB-backed equivalent.
    class InFlightRegistry
      def initialize
        @mutex = Mutex.new
        @runs = {}        # run_uid -> { started_at:, container_ids: [...] }
      end

      # Mark a run as in-flight. No-op on duplicate (idempotent enter).
      def register_run(run_uid)
        @mutex.synchronize do
          @runs[run_uid] ||= { started_at: Time.now, container_ids: [] }
        end
      end

      # Remove a run from the registry. No-op if it wasn't there.
      def unregister_run(run_uid)
        @mutex.synchronize do
          @runs.delete(run_uid)
        end
      end

      # Attach a container to a run. Used by DockerRunner.
      def attach_container(run_uid, container_id)
        @mutex.synchronize do
          entry = @runs[run_uid] ||= { started_at: Time.now, container_ids: [] }
          entry[:container_ids] << container_id unless entry[:container_ids].include?(container_id)
        end
      end

      def detach_container(run_uid, container_id)
        @mutex.synchronize do
          entry = @runs[run_uid]
          entry[:container_ids].delete(container_id) if entry
        end
      end

      def container_ids_for(run_uid)
        @mutex.synchronize do
          entry = @runs[run_uid]
          entry ? entry[:container_ids].dup : []
        end
      end

      def in_flight?(run_uid)
        @mutex.synchronize { @runs.key?(run_uid) }
      end

      def in_flight_count
        @mutex.synchronize { @runs.length }
      end

      def in_flight_uids
        @mutex.synchronize { @runs.keys.dup }
      end
    end
  end
end
