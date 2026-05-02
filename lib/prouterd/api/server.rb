require "puma"
require "puma/server"
require "puma/events"

module Prouterd
  module API
    # Embedded Puma launcher. The CLI's `prouter serve` calls Server.run
    # which blocks until the process is signaled (SIGINT/SIGTERM).
    class Server
      DEFAULT_BIND = "127.0.0.1".freeze
      DEFAULT_PORT = 8080

      def self.run(app:, bind: DEFAULT_BIND, port: DEFAULT_PORT, output: $stdout, &on_started)
        new(app: app, bind: bind, port: port, output: output).run(&on_started)
      end

      attr_reader :bind, :port

      def initialize(app:, bind:, port:, output:)
        @app = app
        @bind = bind
        @port = Integer(port)
        @output = output
        @stop_pipe_r, @stop_pipe_w = IO.pipe
      end

      # Starts the server. Yields once the listener is bound (test hook).
      # Blocks until #stop is called or the process receives SIGINT/SIGTERM.
      def run
        server = Puma::Server.new(@app)
        server.add_tcp_listener(@bind, @port)
        @output.puts "prouter serve: listening on http://#{@bind}:#{@port}"

        install_signal_handlers(server)

        server.run
        yield self if block_given?

        # Wait for stop signal (writing to @stop_pipe wakes us).
        @stop_pipe_r.read(1)
        @output.puts "prouter serve: shutting down…"
        server.stop(true)
      end

      def stop
        @stop_pipe_w.write("x") rescue nil
      end

      private

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
