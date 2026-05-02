require "rack"
require "json"

module Prouterd
  module API
    # Rack app for the prouterd daemon.
    #
    # Routes (spec §22):
    #
    #   GET  /v1/status                  health + commit pointers      (open)
    #   GET  /metrics                    Prometheus text format        (open)
    #
    #   GET  /v1/config/running          rendered running config       (admin)
    #   GET  /v1/config/startup          rendered startup config       (admin)
    #   GET  /v1/config/commits          commit history                (admin)
    #   GET  /v1/config/commits/:id      single commit detail          (admin)
    #   POST /v1/config/check            validate uploaded .prc body   (admin)
    #   POST /v1/config/apply            validate + commit             (admin)
    #   POST /v1/config/rollback         body {commit_id}              (admin)
    #
    #   GET  /v1/processes               list                          (admin)
    #   GET  /v1/processes/:name         detail                        (admin)
    #   POST /v1/processes/:name/trigger body event JSON, returns run  (admin)
    #
    #   GET  /v1/runs?process=&status=   list                          (admin)
    #   GET  /v1/runs/:uid               detail with steps             (admin)
    #   GET  /v1/runs/:uid/logs          logs (filterable)             (admin)
    #   GET  /v1/runs/:uid/artifacts     list                          (admin)
    #   POST /v1/runs/:uid/replay        body {from_block?}            (admin)
    #   POST /v1/runs/:uid/cancel        soft + hard cancel            (admin)
    #
    #   POST /v1/trace                   body {event, interface?}      (admin)
    #
    #   POST /i/<interface_name>         webhook ingestion             (per-iface auth)
    #
    # Admin auth: bearer token from ENV PROUTERD_ADMIN_TOKEN. If unset,
    # /v1/* endpoints are open — fine for local dev, not for production.
    # The daemon prints a warning at boot when unset.
    class App
      WEBHOOK_PATH = %r{\A/i/(?<name>[A-Za-z_][A-Za-z0-9_-]*)\z}.freeze

      def initialize(store:, runner:, secret_resolver: nil, logger: nil,
                     in_flight: nil, metrics: nil, admin_token: nil,
                     jobs: nil, rate_limiter: nil)
        @store = store
        @runner = runner
        @secret_resolver = secret_resolver || Runtime::EnvSecretResolver.new
        @logger = logger
        @in_flight = in_flight
        @metrics = metrics
        @admin_token = admin_token
        @jobs = jobs
        @rate_limiter = rate_limiter
        @accepting = true

        @webhook_handler = WebhookHandler.new(
          store: @store,
          runner: @runner,
          secret_resolver: @secret_resolver,
          logger: @logger,
          in_flight: @in_flight,
          metrics: @metrics,
          jobs: @jobs,
          rate_limiter: @rate_limiter
        )
        @v1 = V1.new(
          store: @store,
          runner: @runner,
          secret_resolver: @secret_resolver,
          in_flight: @in_flight,
          metrics: @metrics,
          logger: @logger,
          jobs: @jobs
        )
      end

      # Begin graceful shutdown: state-changing requests get 503; /v1/status,
      # /metrics, and read-only GETs continue to answer so dashboards survive.
      def stop_accepting
        @accepting = false
      end

      def accepting?
        @accepting
      end

      def call(env)
        request = Rack::Request.new(env)
        method = request.request_method
        path = request.path_info

        return status_response if method == "GET" && path == "/v1/status"
        return metrics_response if method == "GET" && path == "/metrics"

        if !@accepting && !readonly?(method, path)
          return json_response(503, error: "daemon is shutting down — try again later")
        end

        if path.start_with?("/v1/")
          return dispatch_v1(method, path, request)
        end

        if (m = WEBHOOK_PATH.match(path))
          return @webhook_handler.handle(m[:name], request)
        end

        not_found
      rescue StandardError => e
        @logger&.error("API error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        json_response(500, error: "internal server error")
      end

      private

      def readonly?(method, path)
        method == "GET"
      end

      def dispatch_v1(method, path, request)
        auth_err = check_admin(request)
        return auth_err if auth_err

        segments = path.split("/").reject(&:empty?) # ["v1", ...]

        case [method, segments]
        when ["GET",    %w[v1 config running]]   then @v1.get_config_running(request)
        when ["GET",    %w[v1 config startup]]   then @v1.get_config_startup(request)
        when ["GET",    %w[v1 config commits]]   then @v1.get_config_commits(request)
        when ["POST",   %w[v1 config check]]     then @v1.post_config_check(request)
        when ["POST",   %w[v1 config apply]]     then @v1.post_config_apply(request)
        when ["POST",   %w[v1 config rollback]]  then @v1.post_config_rollback(request)
        when ["GET",    %w[v1 processes]]        then @v1.get_processes(request)
        when ["GET",    %w[v1 runs]]             then @v1.get_runs(request)
        when ["POST",   %w[v1 trace]]            then @v1.post_trace(request)
        else
          dispatch_v1_dynamic(method, segments, request)
        end
      end

      def dispatch_v1_dynamic(method, segments, request)
        case
        when method == "GET" && segments.length == 4 && segments[0..2] == %w[v1 config commits]
          @v1.get_config_commit(request, segments[3])
        when method == "GET" && segments.length == 3 && segments[0..1] == %w[v1 processes]
          @v1.get_process(request, segments[2])
        when method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 processes] && segments[3] == "trigger"
          @v1.post_process_trigger(request, segments[2])
        when method == "GET" && segments.length == 3 && segments[0..1] == %w[v1 runs]
          @v1.get_run(request, segments[2])
        when method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "logs"
          @v1.get_run_logs(request, segments[2])
        when method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "artifacts"
          @v1.get_run_artifacts(request, segments[2])
        when method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "replay"
          @v1.post_run_replay(request, segments[2])
        when method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "cancel"
          @v1.post_run_cancel(request, segments[2])
        else
          json_response(404, error: "no /v1 route for #{method} /#{segments.join('/')}")
        end
      end

      def check_admin(request)
        return nil if @admin_token.nil? || @admin_token.empty? # open mode

        header = request.get_header("HTTP_AUTHORIZATION").to_s
        return json_response(401, error: "missing bearer token") unless header.start_with?("Bearer ")

        provided = header.sub(/\ABearer\s+/, "").strip
        return json_response(401, error: "missing bearer token") if provided.empty?
        return nil if Rack::Utils.secure_compare(provided, @admin_token)

        json_response(403, error: "admin token rejected")
      end

      def status_response
        document = @store.load_running
        body = {
          version: Prouterd::VERSION,
          router: document.router&.name,
          hostname: document.router&.hostname,
          interfaces: document.interfaces.length,
          processes: document.processes.length,
          running_commit: @store.running_commit&.id,
          startup_commit: @store.startup_commit&.id,
          accepting: @accepting,
          in_flight: @in_flight&.in_flight_count
        }
        json_response(200, body)
      end

      def metrics_response
        return json_response(200, error: "metrics not configured") unless @metrics

        [200, { "content-type" => "text/plain; version=0.0.4" }, [@metrics.render]]
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
