# frozen_string_literal: true

module Prouterd
  module API
    # Per-interface request rate limiter for webhook ingestion.
    #
    # Implementation: simple sliding window — for each key, keep a deque of
    # recent request timestamps trimmed to `window_seconds`. If the deque
    # length exceeds `max_requests`, allow? returns false. Thread-safe via
    # a single mutex (contention is brief — append + trim is O(1)
    # amortized).
    #
    # Defaults are loose (60 req/sec/interface). Override per-process via
    # PROUTERD_WEBHOOK_RATE env in the form "MAX/WINDOW" (e.g. "100/60").
    class RateLimiter
      DEFAULT_MAX = 60
      DEFAULT_WINDOW = 1 # seconds

      def self.from_env
        spec = ENV["PROUTERD_WEBHOOK_RATE"]
        return new if spec.nil? || spec.empty?

        m = spec.match(/\A(\d+)\/(\d+)\z/) or return new
        new(max_requests: m[1].to_i, window_seconds: m[2].to_i)
      end

      # How often (in seconds) to walk the bucket map and drop entries
      # whose deque is empty after window-trim. Stops the map from
      # growing unbounded when many distinct interface names go quiet.
      EVICT_INTERVAL = 60

      def initialize(max_requests: DEFAULT_MAX, window_seconds: DEFAULT_WINDOW)
        @max = max_requests
        @window = window_seconds
        @mutex = Mutex.new
        @buckets = Hash.new { |h, k| h[k] = [] }
        @last_evict = Time.now.to_f
      end

      def allow?(key)
        now = Time.now.to_f
        cutoff = now - @window
        @mutex.synchronize do
          maybe_evict(now)
          bucket = @buckets[key]
          bucket.shift while bucket.first && bucket.first < cutoff
          if bucket.length >= @max
            false
          else
            bucket << now
            true
          end
        end
      end

      def stats(key)
        @mutex.synchronize { @buckets[key].length }
      end

      def bucket_count
        @mutex.synchronize { @buckets.length }
      end

      private

      # Walk the bucket map periodically and drop entries that have aged
      # completely out of the window. Caller must hold @mutex.
      def maybe_evict(now)
        return if (now - @last_evict) < EVICT_INTERVAL

        cutoff = now - @window
        @buckets.each do |k, bucket|
          bucket.shift while bucket.first && bucket.first < cutoff
        end
        @buckets.delete_if { |_, bucket| bucket.empty? }
        @last_evict = now
      end
    end
  end
end
