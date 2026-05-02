require "rack"
require "json"

module Prouterd
  module API
    # Rack app exposing the Phase 7 surface:
    #
    #   GET  /v1/status                — health + version info
    #   POST /i/<interface_name>       — webhook ingestion
    #
    # The remaining /v1/* endpoints from spec §22.2 are deliberately
    # absent — they belong to Phase 8 hardening.
    class App
      WEBHOOK_PATH = %r{\A/i/(?<name>[A-Za-z_][A-Za-z0-9_-]*)\z}.freeze

      def initialize(store:, runner:, secret_resolver: nil, logger: nil)
        @store = store
        @runner = runner
        @secret_resolver = secret_resolver || Runtime::EnvSecretResolver.new
        @logger = logger
        @webhook_handler = WebhookHandler.new(
          store: @store,
          runner: @runner,
          secret_resolver: @secret_resolver,
          logger: @logger
        )
      end

      def call(env)
        request = Rack::Request.new(env)
        method = request.request_method
        path = request.path_info

        if method == "GET" && path == "/v1/status"
          return status_response
        end

        if method == "POST" && (m = WEBHOOK_PATH.match(path))
          return @webhook_handler.handle(m[:name], request)
        end

        not_found
      rescue StandardError => e
        @logger&.error("API error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        json_response(500, error: "internal server error")
      end

      private

      def status_response
        document = @store.load_running
        body = {
          version: Prouterd::VERSION,
          router: document.router&.name,
          hostname: document.router&.hostname,
          interfaces: document.interfaces.length,
          processes: document.processes.length,
          running_commit: @store.running_commit&.id,
          startup_commit: @store.startup_commit&.id
        }
        json_response(200, body)
      end

      def not_found
        json_response(404, error: "no route for this request")
      end

      def json_response(status, payload)
        [status, { "content-type" => "application/json" }, [JSON.dump(payload)]]
      end
    end
  end
end
