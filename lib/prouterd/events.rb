module Prouterd
  # In-process publish/subscribe bus for domain events.
  #
  # The runtime announces state transitions (run/step/log lifecycle) here
  # so any number of in-process subscribers — internal (metrics, audit,
  # cluster coordination) or external (the API daemon's /v1/events WS,
  # third-party listeners) — can react without polling SQLite.
  #
  # Intentionally minimal:
  #   * synchronous fan-out (callbacks run in publisher's thread)
  #   * no persistence, no replay, no ordering across topics
  #   * single subscriber failure does not poison the bus
  #
  # Subscribers must keep callbacks fast and non-blocking. Any IO,
  # serialization, or slow work belongs behind a per-subscriber queue.
  #
  # Topics emitted by the runtime (Orchestrator):
  #
  #   :run_created   payload: Storage::Run     — row inserted (queued)
  #   :run_updated   payload: Storage::Run     — status / finished_at changed
  #   :step_created  payload: Storage::Step    — new attempt row
  #   :step_updated  payload: Storage::Step    — status / output changed
  #   :log_appended  payload: Storage::LogEntry — new line written
  #
  # Topics are plain symbols at the bus level. Higher layers (e.g. the
  # /v1/events WS endpoint) translate to wire-format topic strings such
  # as "runs", "run:<uid>", "logs:<uid>" with their own filtering.
  class Events
    def initialize
      @mutex       = Mutex.new
      @subscribers = {}
      @next_id     = 0
    end

    # Register a callable. Returns an opaque handle for #unsubscribe.
    def subscribe(topic, &block)
      raise ArgumentError, "block required" unless block

      @mutex.synchronize do
        @next_id += 1
        (@subscribers[topic] ||= {})[@next_id] = block
        [topic, @next_id]
      end
    end

    def unsubscribe(handle)
      return unless handle

      topic, id = handle
      @mutex.synchronize do
        bucket = @subscribers[topic]
        next unless bucket

        bucket.delete(id)
        @subscribers.delete(topic) if bucket.empty?
      end
    end

    # Fan out to current subscribers of `topic`. Iterates over a snapshot
    # so subscribers added/removed during dispatch don't perturb the run.
    def publish(topic, payload)
      callbacks = @mutex.synchronize { @subscribers[topic]&.values&.dup || [] }
      callbacks.each do |cb|
        begin
          cb.call(topic, payload)
        rescue StandardError => e
          warn "[prouterd/events] subscriber error on #{topic.inspect}: #{e.class}: #{e.message}"
        end
      end
    end

    def subscribers_count(topic)
      @mutex.synchronize { @subscribers[topic]&.size || 0 }
    end

    def has_subscribers?(topic)
      subscribers_count(topic).positive?
    end

    def topics
      @mutex.synchronize { @subscribers.keys.dup }
    end

    # Clears every subscription. Test-only helper; production code never
    # needs this since callers manage their own handles.
    def clear
      @mutex.synchronize do
        @subscribers.clear
        @next_id = 0
      end
    end

    # Process-wide singleton used by the Orchestrator when no bus is
    # injected. Tests inject their own instance via `events:` constructor
    # parameter to keep concurrent specs isolated.
    DEFAULT = new

    class << self
      def default
        DEFAULT
      end

      def subscribe(topic, &block)
        DEFAULT.subscribe(topic, &block)
      end

      def publish(topic, payload)
        DEFAULT.publish(topic, payload)
      end

      def unsubscribe(handle)
        DEFAULT.unsubscribe(handle)
      end
    end
  end
end
