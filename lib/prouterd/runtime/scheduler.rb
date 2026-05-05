require "time"

module Prouterd
  module Runtime
    # Cron scheduler that fires triggers for `interface cron` declarations.
    #
    # The `fugit` gem is an OPTIONAL dependency — installs that don't use
    # `interface cron` don't need it. When fugit is not installed, the
    # scheduler logs once at warmup, treats every cron interface as
    # un-parseable, and otherwise no-ops; the daemon as a whole keeps
    # running.
    #
    # Runs as a background thread inside `prouter serve`. Once per tick
    # (TICK_SECONDS, default 1s) it:
    #
    #   1. Re-loads running config (so commits during life take effect).
    #   2. For each non-shutdown cron interface, looks up the global route
    #      pointing at it, and computes whether the cron expression should
    #      have fired since the last tick.
    #   3. For each fire, builds a minimal event ({"fired_at": ts}) and
    #      enqueues + asynchronously executes a run.
    #
    # Per-interface "last fired at" is held in-memory; on daemon restart we
    # treat the recovery sweep as the boundary and start tracking forward.
    # That means a cron job missed during a daemon outage is genuinely
    # missed; sophisticated catch-up logic is intentionally out of scope
    # for v0.1 and a simple skip-during-outage matches that.
    class Scheduler
      def self.fugit_available?
        return @fugit_available unless @fugit_available.nil?

        @fugit_available = begin
          require "fugit"
          true
        rescue LoadError
          false
        end
      end

      TICK_SECONDS = 1.0

      def self.run(store:, runner:, jobs:, logger: NullLogger.new, in_flight: nil, metrics: nil)
        new(store: store, runner: runner, jobs: jobs, logger: logger,
            in_flight: in_flight, metrics: metrics).run
      end

      def initialize(store:, runner:, jobs:, logger: NullLogger.new, in_flight: nil, metrics: nil)
        @store = store
        @runner = runner
        @jobs = jobs
        @logger = logger
        @in_flight = in_flight
        @metrics = metrics
        @stopping = false
        @last_fired = {} # interface_name -> Time
        @tick_seconds = TICK_SECONDS
      end

      def stop
        @stopping = true
      end

      def run
        Thread.new do
          warmup
          loop do
            break if @stopping

            tick
            sleep(@tick_seconds)
          rescue StandardError => e
            @logger.error("scheduler: tick error", error: e.class.name, message: e.message)
          end
        end
      end

      # Single-tick scan, exposed as public for testability.
      def tick(now: Time.now)
        document = @store.load_running
        cron_interfaces = document.interfaces.select { |i| i.cron? && !i.shutdown }
        return if cron_interfaces.empty?

        cron_interfaces.each do |iface|
          fire_if_due(iface, document, now)
        end
      end

      private

      # Initialize @last_fired so we don't immediately re-fire jobs whose
      # next_time is in the past relative to the daemon's start.
      def warmup
        @last_fired_warm = Time.now
      end

      def fire_if_due(iface, document, now)
        cron = parse_cron(iface)
        return unless cron

        last = @last_fired[iface.name] || @last_fired_warm || (now - @tick_seconds)
        next_at = cron.next_time(last).to_t
        return if next_at > now

        # Catch up any missed fires by walking next_time forward to `now`.
        while next_at <= now
          dispatch(iface, document, next_at)
          last = next_at
          next_at = cron.next_time(last).to_t
          break if next_at == last # safety
        end
        @last_fired[iface.name] = last
      end

      def parse_cron(iface)
        schedule = iface.type_fields["schedule"]
        return nil unless schedule

        unless self.class.fugit_available?
          unless @fugit_warned
            @logger.warn("scheduler: 'fugit' gem not installed; cron interfaces disabled (gem install fugit)")
            @fugit_warned = true
          end
          return nil
        end

        # Fugit accepts a trailing timezone in the cron expression itself:
        # "0 9 * * * Europe/Berlin". We append the interface's `timezone`
        # field if set so users keep DSL-level timezone configuration.
        timezone = iface.type_fields["timezone"]
        expr = timezone ? "#{schedule} #{timezone}" : schedule
        Fugit.parse_cron(expr)
      rescue StandardError
        @logger.warn("scheduler: invalid cron expression",
                     interface: iface.name, schedule: iface.type_fields["schedule"].inspect)
        nil
      end

      def dispatch(iface, document, fired_at)
        route = document.global_routes.find { |r| r.interface_name == iface.name }
        unless route
          @logger.warn("scheduler: cron has no global route — skipping fire", interface: iface.name)
          return
        end
        process = document.processes.find { |p| p.name == route.process_name }
        unless process
          @logger.warn("scheduler: cron targets unknown process",
                       interface: iface.name, process: route.process_name)
          return
        end
        return if process.shutdown

        event = { "fired_at" => fired_at.utc.iso8601(3), "interface" => iface.name }
        ctx = Context.new("event" => event)
        return unless MatchEvaluator.passes?(route.matches, ctx)

        orchestrator = Orchestrator.new(
          db: @store.db, runner: @runner, in_flight: @in_flight, metrics: @metrics
        )
        run = orchestrator.enqueue(
          document, process.name,
          input_event: event,
          interface_name: iface.name,
          commit_id: @store.running_commit&.id
        )
        @metrics&.increment(:cron_fires_total, interface: iface.name)
        @logger.info("scheduler: fired cron",
                     interface: iface.name, run_id: run.uid, fired_at: fired_at.utc.iso8601(0))

        @jobs.enqueue(run_id: run.id, kind: "execute")
      end
    end
  end
end
