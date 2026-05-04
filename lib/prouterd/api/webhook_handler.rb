require "json"

module Prouterd
  module API
    # Handles `POST /i/<interface_name>` requests.
    #
    # Flow:
    #   1. Resolve the interface from the running config; reject if missing,
    #      not webhook, or shutdown.
    #   2. Authenticate (bearer) if the interface declares `auth`.
    #   3. Parse the request body as JSON. Empty body => empty event.
    #   4. Find the matching global route. Evaluate any match conditions
    #      against the event.
    #   5. Enqueue a Run row + a job onto the durable JobQueue, return
    #      `{run_id, status: queued}` immediately. The WorkerPool drains
    #      the queue; daemon crash mid-run is recoverable.
    class WebhookHandler
      def initialize(store:, runner:, jobs:, secret_resolver: nil,
                     logger: Prouterd::NullLogger.new,
                     in_flight: nil, metrics: nil, rate_limiter: nil)
        @store = store
        @runner = runner
        @jobs = jobs
        @secret_resolver = secret_resolver || Runtime::EnvSecretResolver.new
        @logger = logger
        @in_flight = in_flight
        @metrics = metrics
        @rate_limiter = rate_limiter
      end

      # Returns [status, headers, body_string] for the Rack response.
      def handle(interface_name, request)
        document = @store.load_running

        interface = document.interfaces.find { |i| i.name == interface_name }
        return json_error(404, "unknown interface '#{interface_name}'") unless interface
        return json_error(404, "interface '#{interface_name}' is not a webhook") unless interface.webhook?
        return json_error(503, "interface '#{interface_name}' is shutdown") if interface.shutdown

        # Method enforcement: webhook interfaces declare a `method`.
        # Default to POST when not declared so existing fixtures keep working.
        expected_method = (interface.method || "POST").to_s.upcase
        actual_method = request.request_method.to_s.upcase
        if actual_method != expected_method
          return json_error(405, "method '#{actual_method}' not allowed; interface accepts '#{expected_method}'",
                            headers: { "allow" => expected_method })
        end

        # Per-interface rate limit (sliding window). Returns 429 with the
        # configured limit in the body so a client can back off intelligently.
        if @rate_limiter && !@rate_limiter.allow?(interface_name)
          @metrics&.increment(:webhooks_received_total, interface: interface_name, code: 429)
          return json_error(429, "rate limit exceeded for interface '#{interface_name}'")
        end

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

        orchestrator = Runtime::Orchestrator.new(
          db: @store.db, runner: @runner, in_flight: @in_flight
        )
        run = orchestrator.enqueue(
          document,
          process.name,
          input_event: event,
          interface_name: interface_name,
          commit_id: @store.running_commit&.id
        )

        @jobs.enqueue(run_id: run.id, kind: "execute")
        @metrics&.increment(:webhooks_received_total, interface: interface_name, code: 202)

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

      def json_error(status, message, headers: {})
        [status, { "content-type" => "application/json" }.merge(headers), [JSON.dump(error: message)]]
      end
    end
  end
end
