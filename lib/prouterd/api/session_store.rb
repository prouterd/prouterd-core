# frozen_string_literal: true

require "securerandom"

module Prouterd
  module API
    # In-memory cookie session store for the operator console.
    #
    # POST /v1/login validates the bearer once, stores a fresh
    # session_id, and the daemon hands it back to the browser as an
    # HttpOnly cookie. Every subsequent request that carries that
    # cookie skips the bearer comparison entirely — the bearer never
    # touches the JS layer again, which closes the XSS-leak vector
    # operators worry about for internet-facing deploys.
    #
    # Sessions live in process memory only. Daemon restart drops them;
    # the browser re-logs in. That's acceptable for an operator
    # surface and lets us avoid cross-process invalidation logic.
    #
    # Concurrent access from Puma worker threads is guarded by a single
    # mutex; the cost is negligible compared to a DB round-trip.
    class SessionStore
      DEFAULT_TTL_SECONDS = 24 * 60 * 60   # 24h since last touch

      def initialize(ttl: DEFAULT_TTL_SECONDS, clock: -> { Time.now })
        @ttl   = ttl
        @clock = clock
        @sessions = {}     # session_id => last_seen_at
        @mutex = Mutex.new
      end

      # Returns a new opaque session id (256-bit hex).
      def create
        sid = SecureRandom.hex(32)
        @mutex.synchronize { @sessions[sid] = @clock.call }
        sid
      end

      # True if the id corresponds to a session that hasn't aged out.
      # Sliding window: each successful check refreshes last_seen_at,
      # so an active operator never gets bounced.
      def valid?(sid)
        return false if sid.nil? || sid.empty?

        @mutex.synchronize do
          last = @sessions[sid]
          return false unless last
          if @clock.call - last > @ttl
            @sessions.delete(sid)
            return false
          end
          @sessions[sid] = @clock.call
          true
        end
      end

      # Drop a session. Idempotent.
      def revoke(sid)
        @mutex.synchronize { @sessions.delete(sid) }
      end

      # Ops / metrics surface — current live count after sweeping
      # expired entries.
      def size
        @mutex.synchronize do
          now = @clock.call
          @sessions.delete_if { |_, last| now - last > @ttl }
          @sessions.size
        end
      end
    end
  end
end
