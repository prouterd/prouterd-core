# frozen_string_literal: true

module Prouterd
  module Iface
    # Process-singleton store of the most recent `auto-pull` outcome
    # per `interface local_repo` × repo. Scheduler writes here after
    # each `git pull --ff-only`; V1 reads it so operators can answer
    # "what's the freshness state of my local_repo whitelist?" without
    # grepping the daemon log.
    #
    # Lossy by design: only the latest record per (iface, repo) is
    # kept. For full history → daemon log via `show logging
    # facility SCHED`.
    module LocalRepoStatus
      module_function

      Record = Struct.new(:iface_name, :repo, :ok, :checked_at,
                          :summary, :error, keyword_init: true) do
        def to_h
          {
            iface_name: iface_name,
            repo:       repo,
            ok:         ok,
            checked_at: checked_at,
            summary:    summary,
            error:      error
          }
        end
      end

      def store
        @store ||= {}
      end

      def lock
        @lock ||= Mutex.new
      end

      def record_pull(iface_name:, repo:, ok:, summary: nil, error: nil)
        rec = Record.new(
          iface_name: iface_name, repo: repo, ok: ok,
          checked_at: Time.now.utc.iso8601(3),
          summary: summary, error: error
        )
        lock.synchronize do
          store[[iface_name, repo]] = rec
        end
      end

      # Returns Array<Record> across every (iface, repo) pair. Filtered
      # to a single iface when `iface_name:` given.
      def snapshot(iface_name: nil)
        lock.synchronize do
          rows = store.values
          rows = rows.select { |r| r.iface_name == iface_name } if iface_name
          rows.dup
        end
      end

      # Test-only — not used in production. Drains the singleton store
      # so cross-spec leakage doesn't happen.
      def reset!
        lock.synchronize { store.clear }
      end
    end
  end
end
