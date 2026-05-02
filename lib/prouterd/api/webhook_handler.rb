require "json"

module Prouterd
  module API
    # Handles `POST /i/<interface_name>` requests.
    #
    # Flow per spec §22.3:
    #   1. Resolve the interface from the running config; reject if missing,
    #      not webhook, or shutdown.
    #   2. Authenticate (bearer) if the interface declares `auth`.
    #   3. Parse the request body as JSON. Empty body => empty event.
    #   4. Find the matching global route. Evaluate any match conditions
    #      against the event.
    #   5. Enqueue a Run row, return `{run_id, status: queued}` immediately.
    #   6. Dispatch async execution onto an internal Thread (Phase 7) — a
    #      proper worker pool with crash recovery is Phase 8 territory.
    class WebhookHandler
      def initialize(store:, runner:, secret_resolver: nil, logger: nil)
        @store = store
        @runner = runner
        @secret_resolver = secret_resolver || Runtime::EnvSecretResolver.new
        @logger = logger
      end

      # Returns [status, headers, body_string] for the Rack response.
      def handle(interface_name, request)
        document = @store.load_running

        interface = document.interfaces.find { |i| i.name == interface_name }
        return json_error(404, "unknown interface '#{interface_name}'") unless interface
        return json_error(404, "interface '#{interface_name}' is not a webhook") unless interface.webhook?
        return json_error(503, "interface '#{interface_name}' is shutdown") if interface.shutdown

        if interface.auth
          token = resolve_secret(document, interface.auth.secret_name)
          err = Auth.check_bearer(request, token)
          return json_error(*err) if err
        end

        event = parse_body(request)
        return event if event.is_a?(Array) # Already a [status, body] error tuple

        route = document.global_routes.find { |r| r.interface_name == interface_name }
        return json_error(404, "no global route configured for interface '#{interface_name}'") unless route

        ctx = Runtime::Context.new("event" => event)
        unless Runtime::MatchEvaluator.passes?(route.matches, ctx)
          return json_error(422, "event did not match route conditions")
        end

        process = document.processes.find { |p| p.name == route.process_name }
        return json_error(500, "global route targets unknown process '#{route.process_name}'") unless process
        return json_error(503, "process '#{process.name}' is shutdown") if process.shutdown

        orchestrator = Runtime::Orchestrator.new(db: @store.db, runner: @runner)
        run = orchestrator.enqueue(
          document,
          process.name,
          input_event: event,
          interface_name: interface_name,
          commit_id: @store.running_commit&.id
        )

        dispatch_async(orchestrator, run, document)

        body = JSON.dump(
          run_id: run.uid,
          status: "queued"
        )
        [202, { "content-type" => "application/json" }, [body]]
      end

      private

      def resolve_secret(document, name)
        secret = document.secrets.find { |s| s.name == name }
        return nil unless secret

        @secret_resolver.resolve(secret)
      end

      def parse_body(request)
        raw = request.body&.read.to_s
        return {} if raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        json_error(400, "request body is not valid JSON: #{e.message}")
      end

      def dispatch_async(orchestrator, run, document)
        Thread.new do
          begin
            orchestrator.execute_run(run, document)
          rescue StandardError => e
            @logger&.error("run #{run.uid} crashed: #{e.class} #{e.message}")
            # Best-effort mark the run failed; if the DB call also fails,
            # we drop the error since the request thread is long gone.
            begin
              repo = Storage::Repositories::Runs.new(@store.db)
              repo.update_run(
                run.id,
                status: "failed",
                finished_at: Time.now.utc.iso8601(3),
                error_summary: "orchestrator crash: #{e.class}: #{e.message}"
              )
            rescue StandardError
              # swallow
            end
          end
        end
      end

      def json_error(status, message)
        [status, { "content-type" => "application/json" }, [JSON.dump(error: message)]]
      end
    end
  end
end
