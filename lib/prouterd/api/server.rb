require "puma"
require "puma/server"
require "puma/events"

module Prouterd
  module API
    # Embedded Puma launcher. The CLI's `prouter serve` calls Server.run
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
    # The Scheduler is stopped externally (in `prouter serve` via `ensure`).
    class Server
      DEFAULT_BIND = "127.0.0.1".freeze
      DEFAULT_PORT = 8080
      DEFAULT_DRAIN_TIMEOUT = 30

      def self.run(app:, bind: DEFAULT_BIND, port: DEFAULT_PORT, output: $stdout,
                   in_flight: nil, drain_timeout: DEFAULT_DRAIN_TIMEOUT, &on_started)
        new(
          app: app, bind: bind, port: port, output: output,
          in_flight: in_flight, drain_timeout: drain_timeout
        ).run(&on_started)
      end

      attr_reader :bind, :port

      def initialize(app:, bind:, port:, output:, in_flight: nil, drain_timeout: DEFAULT_DRAIN_TIMEOUT)
        @app = app
        @bind = bind
        @port = Integer(port)
        @output = output
        @in_flight = in_flight
        @drain_timeout = drain_timeout
        @stop_pipe_r, @stop_pipe_w = IO.pipe
      end

      def run
        server = Puma::Server.new(@app)
        server.add_tcp_listener(@bind, @port)
        @output.puts "prouter serve: listening on http://#{@bind}:#{@port}"

        install_signal_handlers(server)

        server.run
        yield self if block_given?

        @stop_pipe_r.read(1)

        @output.puts "prouter serve: shutdown signal received; refusing new state-changing requests"
        @app.stop_accepting if @app.respond_to?(:stop_accepting)

        drain_in_flight if @in_flight

        @output.puts "prouter serve: stopping HTTP listener…"
        server.stop(true)
      end

      def stop
        @stop_pipe_w.write("x") rescue nil
      end

      private

      def drain_in_flight
        deadline = Time.now + @drain_timeout
        loop do
          remaining = @in_flight.in_flight_count
          break if remaining.zero?

          if Time.now >= deadline
            uids = @in_flight.in_flight_uids
            @output.puts "prouter serve: drain timed out with #{remaining} run(s) still in flight: #{uids.join(', ')}"
            break
          end

          @output.puts "prouter serve: waiting for #{remaining} in-flight run(s) to finish…" if (Time.now.to_i % 5).zero?
          sleep 0.2
        end
      end

      def install_signal_handlers(_server)
        %w[INT TERM].each do |sig|
          Signal.trap(sig) { stop }
        rescue ArgumentError
          # Some signals can't be trapped on Windows / some environments.
        end
      end
    end
  end
end
