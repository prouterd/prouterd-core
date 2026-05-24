# frozen_string_literal: true

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
      include BodyReader

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
        return json_error(404, "not_found", "unknown interface '#{interface_name}'") unless interface
        return json_error(404, "not_found", "interface '#{interface_name}' is not a webhook") unless interface.webhook?
        return json_error(503, "unavailable", "interface '#{interface_name}' is shutdown") if interface.shutdown

        # Method enforcement: webhook interfaces declare a `method`.
        # Default to POST when not declared so existing fixtures keep working.
        expected_method = (interface.type_fields["method"] || "POST").to_s.upcase
        actual_method = request.request_method.to_s.upcase
        if actual_method != expected_method
          return json_error(405, "method_not_allowed",
                            "method '#{actual_method}' not allowed; interface accepts '#{expected_method}'",
                            headers: { "allow" => expected_method })
        end

        # Per-interface rate limit (sliding window). Returns 429 with the
        # configured limit in the body so a client can back off intelligently.
        if @rate_limiter && !@rate_limiter.allow?(interface_name)
          @metrics&.increment(:webhooks_received_total, interface: interface_name, code: 429)
          return json_error(429, "rate_limited", "rate limit exceeded for interface '#{interface_name}'")
        end

        if (auth = interface.type_fields["auth"])
          token = resolve_secret(document, auth.secret_name)
          err = Auth.check_bearer(request, token)
          return json_error(*err) if err
        end

        # HMAC-SHA256 body signature verification (Phase 38g). Reads
        # the raw body once, computes the digest, compares against the
        # named header. Some providers (Slack `v0=<hex>`, GitHub
        # `sha256=<hex>`) prefix the digest with a versioned scheme tag
        # — strip up to and including the first `=` before comparing.
        raw_body = nil
        if (sig = interface.type_fields["hmac-sha256"])
          raw_body = read_raw_body(request)
          secret = resolve_secret(document, sig.secret_name)
          if secret.nil? || secret.empty?
            @logger.error("hmac-sha256 secret unresolved",
                          facility: "SECRET", mnemonic: "MISSING",
                          interface: interface_name, secret: sig.secret_name)
            return json_error(500, "secret_unresolved", "hmac-sha256: secret '#{sig.secret_name}' not resolved")
          end
          provided = request.get_header("HTTP_" + sig.header.upcase.tr("-", "_")).to_s
          provided = provided.split("=", 2).last if provided.include?("=")
          require "openssl"
          expected = OpenSSL::HMAC.hexdigest("sha256", secret, raw_body)
          unless secure_equal?(provided.downcase, expected.downcase)
            @metrics&.increment(:webhooks_received_total, interface: interface_name, code: 401)
            @logger.warn("hmac signature mismatch",
                         facility: "WEBHOOK", mnemonic: "HMAC_FAIL",
                         interface: interface_name, header: sig.header)
            return json_error(401, "unauthorized", "invalid hmac signature")
          end
        end

        event = parse_body(request, prefetched_body: raw_body)
        return event if event.is_a?(Array) # Already a [status, body] error tuple

        route = document.global_routes.find { |r| r.interface_name == interface_name }
        return json_error(404, "not_found", "no global route configured for interface '#{interface_name}'") unless route

        ctx = Runtime::Context.new("event" => event)
        unless Runtime::MatchEvaluator.passes?(route.matches, ctx)
          return json_error(422, "unprocessable", "event did not match route conditions")
        end

        process = document.processes.find { |p| p.name == route.process_name }
        return json_error(500, "internal_error", "global route targets unknown process '#{route.process_name}'") unless process
        return json_error(503, "unavailable", "process '#{process.name}' is shutdown") if process.shutdown

        orchestrator = Runtime::Orchestrator.new(
          db: @store.db, runner: @runner, in_flight: @in_flight
        )

        # Phase 34a: run row insert + job-queue insert must land or roll
        # back together. Without the wrapping transaction a disk-full
        # mid-pair would leave a `queued` run with no matching job —
        # invisible to workers, eternal on dashboards.
        run = nil
        @store.db.transaction do
          run = orchestrator.enqueue(
            document,
            process.name,
            input_event: event,
            interface_name: interface_name,
            commit_id: @store.running_commit&.id
          )
          @jobs.enqueue(run_id: run.id, kind: "execute")
        end
        @metrics&.increment(:webhooks_received_total, interface: interface_name, code: 202)
        @logger.info("webhook accepted",
                     facility: "WEBHOOK", mnemonic: "ACCEPTED",
                     interface: interface_name, process: process.name, run_uid: run.uid)

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

      def parse_body(request, prefetched_body: nil)
        raw = prefetched_body || read_raw_body(request)
        return {} if raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError => e
        json_error(400, "bad_json", "request body is not valid JSON: #{e.message}")
      end

      def read_raw_body(request)
        # Body IO is a one-shot reader; cache the bytes so HMAC verify
        # and JSON parse don't fight over it.
        read_bounded_body(request).to_s
      end

      def secure_equal?(a, b)
        return false if a.bytesize != b.bytesize

        # constant-time comparison to avoid timing leaks on the hex
        # digest. OpenSSL.fixed_length_secure_compare exists on Ruby
        # 2.5+; we're on >=3.2.
        OpenSSL.fixed_length_secure_compare(a, b)
      end

      # Canonical `{error: {code, message, details?}}` envelope. `code`
      # is a stable identifier clients can branch on. The signature is
      # `(status, code, message, headers:, details:)` so call sites
      # read like `json_error(404, "not_found", "unknown interface")`.
      def json_error(status, code, message, headers: {}, details: nil)
        body = { code: code, message: message }
        body[:details] = details unless details.nil?
        [status, { "content-type" => "application/json" }.merge(headers),
         [JSON.dump(error: body)]]
      end
    end
  end
end
