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

      def initialize(max_requests: DEFAULT_MAX, window_seconds: DEFAULT_WINDOW)
        @max = max_requests
        @window = window_seconds
        @mutex = Mutex.new
        @buckets = Hash.new { |h, k| h[k] = [] }
      end

      def allow?(key)
        now = Time.now.to_f
        cutoff = now - @window
        @mutex.synchronize do
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
    end
  end
end
