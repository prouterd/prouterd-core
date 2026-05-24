# frozen_string_literal: true

require "puma"
require "puma/server"
require "puma/events"

module Prouterd
  module API
    # Embedded Puma launcher. The `prouterd` daemon calls Server.run
    # which blocks until the process is signaled (SIGINT/SIGTERM).
    #
    # Graceful shutdown sequence on SIGINT/SIGTERM:
    #
    #   1. App.stop_accepting → state-changing requests (POST/PUT/DELETE) get
    #      503; GETs to /v1/status, /metrics, and read-only endpoints
    #      continue to work so probes and dashboards stay green.
    #   2. Drain phase: poll the InFlightRegistry every 100ms until
    #      in_flight_count == 0, capped by `drain_timeout_seconds`.
    #   3. Puma stops with `force=true` so any HTTP connection still alive
    #      after drain gets cleanly closed.
    #
    # The Scheduler is stopped externally (in `prouterd` via `ensure`).
    class Server
      DEFAULT_BIND = "127.0.0.1".freeze
      DEFAULT_PORT = 8080
      DEFAULT_DRAIN_TIMEOUT = 30

      def self.run(app:, bind: DEFAULT_BIND, port: DEFAULT_PORT,
                   logger: Prouterd::NullLogger.new,
                   in_flight: nil, drain_timeout: DEFAULT_DRAIN_TIMEOUT,
                   ssl_cert: nil, ssl_key: nil, &on_started)
        new(
          app: app, bind: bind, port: port, logger: logger,
          in_flight: in_flight, drain_timeout: drain_timeout,
          ssl_cert: ssl_cert, ssl_key: ssl_key
        ).run(&on_started)
      end

      attr_reader :bind, :port

      def initialize(app:, bind:, port:, logger: Prouterd::NullLogger.new,
                     in_flight: nil, drain_timeout: DEFAULT_DRAIN_TIMEOUT,
                     ssl_cert: nil, ssl_key: nil)
        @app = app
        @bind = bind
        @port = Integer(port)
        @logger = logger
        @in_flight = in_flight
        @drain_timeout = drain_timeout
        @ssl_cert = ssl_cert.is_a?(String) && !ssl_cert.empty? ? ssl_cert : nil
        @ssl_key  = ssl_key.is_a?(String)  && !ssl_key.empty?  ? ssl_key  : nil
        @stop_pipe_r, @stop_pipe_w = IO.pipe
      end

      def run
        server = Puma::Server.new(@app)
        if @ssl_cert && @ssl_key
          require "puma/minissl"
          ctx = Puma::MiniSSL::Context.new
          ctx.cert = @ssl_cert
          ctx.key  = @ssl_key
          server.add_ssl_listener(@bind, @port, ctx)
          @logger.info("listening (TLS)",
                       facility: "DAEMON", mnemonic: "LISTENING",
                       url: "https://#{@bind}:#{@port}", cert: @ssl_cert)
        else
          server.add_tcp_listener(@bind, @port)
          @logger.info("listening",
                       facility: "DAEMON", mnemonic: "LISTENING",
                       url: "http://#{@bind}:#{@port}")
        end

        install_signal_handlers(server)

        server.run
        yield self if block_given?

        @stop_pipe_r.read(1)

        @logger.notice("shutdown signal received; refusing new state-changing requests",
                       facility: "DAEMON", mnemonic: "SHUTDOWN_SIGNAL")
        @app.stop_accepting if @app.respond_to?(:stop_accepting)

        drain_in_flight if @in_flight

        @logger.notice("stopping HTTP listener",
                       facility: "DAEMON", mnemonic: "LISTENER_STOP")
        server.stop(true)
      end

      def stop
        @stop_pipe_w.write("x") rescue nil
      end

      private

      def drain_in_flight
        deadline = Time.now + @drain_timeout
        loop do
          status = drain_tick(now: Time.now, deadline: deadline)
          break if status != :continue

          sleep 0.2
        end
      end

      # One step of the drain loop. Returns:
      #   :done      — no in-flight runs left
      #   :timed_out — deadline passed; remaining run uids logged
      #   :continue  — work still in flight; caller should sleep + retry
      def drain_tick(now:, deadline:)
        remaining = @in_flight.in_flight_count
        return :done if remaining.zero?

        if now >= deadline
          uids = @in_flight.in_flight_uids
          @logger.warn("drain timed out",
                       facility: "DAEMON", mnemonic: "DRAIN_TIMEOUT",
                       remaining: remaining, run_uids: uids.join(","))
          return :timed_out
        end

        if (now.to_i % 5).zero?
          @logger.info("draining in-flight runs",
                       facility: "DAEMON", mnemonic: "DRAINING",
                       remaining: remaining)
        end
        :continue
      end

      def install_signal_handlers(_server)
        %w[INT TERM].each do |sig|
          trap_signal(sig)
        end
      end

      # `Signal.trap` can ArgumentError on platforms where the signal
      # isn't trappable (Windows / some embedded). Treat as a no-op so
      # daemon boot doesn't abort there.
      def trap_signal(sig)
        Signal.trap(sig) { stop }
      rescue ArgumentError
        nil
      end
    end
  end
end
