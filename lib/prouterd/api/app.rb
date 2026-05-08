require "rack"
require "json"
require "faye/websocket"

module Prouterd
  module API
    # Rack app for the prouterd daemon.
    #
    # Routes:
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
      CLI_WS_PATH  = %r{\A/v1/cli/(?<session_id>[A-Za-z0-9._-]+)\z}.freeze

      def initialize(store:, runner:, jobs:, secret_resolver: nil,
                     logger: Prouterd::NullLogger.new,
                     in_flight: nil, metrics: nil, admin_token: nil,
                     rate_limiter: nil,
                     events: Prouterd::Events.default)
        @store = store
        @runner = runner
        @secret_resolver = secret_resolver || Runtime::EnvSecretResolver.new
        @logger = logger
        @in_flight = in_flight
        @metrics = metrics
        @admin_token = admin_token
        @jobs = jobs
        @rate_limiter = rate_limiter
        @events = events
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
          jobs: @jobs,
          events: @events
        )
        @rpc_dispatcher = RpcDispatcher.new(v1: @v1, app: self, store: @store)
      end

      # Begin graceful shutdown: state-changing requests get 503; /v1/status,
      # /metrics, and read-only GETs continue to answer so dashboards survive.
      def stop_accepting
        @accepting = false
      end

      # Re-enable mutating endpoints. Called by the periodic storage probe
      # once writes are working again.
      def resume_accepting
        @accepting = true
      end

      def accepting?
        @accepting
      end

      # Background storage-health probe. The daemon entry point starts
      # this thread; tests / CLI processes don't. Runs forever, checking
      # `@store.db.healthy?` every PROUTERD_STORAGE_PROBE_SECONDS (default
      # 30). When `@accepting` is currently false and the probe says
      # writes work — flip back. When accepting=true and probe says no —
      # flip off pre-emptively (handler-level rescue covers the case
      # where a request hits a still-broken DB before the probe noticed).
      def start_storage_probe
        return if @storage_probe_thread

        interval = (ENV["PROUTERD_STORAGE_PROBE_SECONDS"] || 30).to_i
        @storage_probe_thread = Thread.new do
          loop do
            sleep interval
            healthy = @store.db.healthy?
            if healthy && !@accepting
              @accepting = true
              @logger.info("storage: writes recovered, accepting requests")
            elsif !healthy && @accepting
              @accepting = false
              @logger.warn("storage: writes failing, rejecting state-changing requests")
            end
          rescue StandardError => e
            @logger.error("storage probe error", error: e.class.name, message: e.message)
          end
        end
      end

      def stop_storage_probe
        @storage_probe_thread&.kill
        @storage_probe_thread = nil
      end

      def call(env)
        request = Rack::Request.new(env)
        method = request.request_method
        path = request.path_info

        return status_response if method == "GET" && path == "/v1/status"
        return metrics_response if method == "GET" && path == "/metrics"

        # WS upgrades for /v1/events and /v1/cli/:sid. Faye::WebSocket
        # hijacks the underlying socket via rack.hijack (Puma supports it),
        # so the regular Rack response cycle is short-circuited.
        if Faye::WebSocket.websocket?(env)
          return dispatch_ws(env, path)
        end

        if !@accepting && !readonly?(method, path)
          return json_response(503, error: "daemon is shutting down — try again later")
        end

        # Reject oversized bodies before any handler reads them. Puma streams
        # the body through, so a 5GB POST would otherwise block a worker
        # thread plus eat memory. Limit is per-request and configurable via
        # PROUTERD_MAX_BODY_BYTES (default 1MB for ingest, lifted to 4MB for
        # /v1/config/apply since DSL files can grow).
        if (err = enforce_body_limit(method, path, request))
          return err
        end

        if path.start_with?("/v1/")
          return dispatch_v1(method, path, request)
        end

        if (m = WEBHOOK_PATH.match(path))
          return @webhook_handler.handle(m[:name], request)
        end

        not_found
      rescue Storage::DiskUnavailableError => e
        # Storage is unwritable — flip into "shutting down" mode so the
        # next request is rejected with 503 instantly. Scheduler's storage
        # probe re-enables accepting once writes recover.
        @accepting = false
        @logger.error("storage unavailable",
                      error: e.class.name, message: e.message)
        json_response(503, error: "storage unavailable", error_type: "storage_unavailable")
      rescue StandardError => e
        @logger.error("API error",
                      error: e.class.name, message: e.message,
                      backtrace: e.backtrace.first(5).join(" | "))
        json_response(500, error: "internal server error")
      end

      DEFAULT_MAX_BODY_BYTES = 1 * 1024 * 1024     # 1 MB for /i/* + most /v1
      DEFAULT_MAX_CONFIG_BYTES = 4 * 1024 * 1024   # 4 MB for /v1/config/apply (DSL files)

      # Same payload that GET /v1/status returns. Exposed publicly so
      # the WS-RPC `status` method (RpcDispatcher) can reuse it.
      def status_payload
        document = @store.load_running
        {
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
      end

      private

      def readonly?(method, path)
        method == "GET"
      end

      def enforce_body_limit(method, path, request)
        # GETs and DELETEs have no body to police. Only police writes.
        return nil if %w[GET HEAD DELETE].include?(method)

        cap = body_cap_for(path)
        # Content-Length header is the cheap path — reject before even
        # reading bytes off the socket. (Puma still streams through to
        # body.read, but Rack exposes the header.)
        cl = request.content_length
        if cl && cl.to_i > cap
          return json_response(413, error: "request body too large",
                                    limit_bytes: cap, content_length: cl.to_i)
        end
        nil
      end

      def body_cap_for(path)
        env_override = ENV["PROUTERD_MAX_BODY_BYTES"]&.to_i
        config_override = ENV["PROUTERD_MAX_CONFIG_BYTES"]&.to_i

        if path == "/v1/config/apply" || path == "/v1/config/check"
          (config_override && config_override.positive? ? config_override : DEFAULT_MAX_CONFIG_BYTES)
        else
          (env_override && env_override.positive? ? env_override : DEFAULT_MAX_BODY_BYTES)
        end
      end

      def dispatch_ws(env, path)
        if path == "/v1/events"
          EventsWebSocket.handle(
            env,
            events:      @events,
            admin_token: @admin_token,
            dispatcher:  @rpc_dispatcher,
            logger:      @logger
          )
        elsif (m = CLI_WS_PATH.match(path))
          CliWebSocket.handle(
            env,
            session_id:  m[:session_id],
            store:       @store,
            admin_token: @admin_token,
            logger:      @logger
          )
        else
          json_response(404, error: "no WS route for #{path}")
        end
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
        when ["POST",   %w[v1 config save-boot]] then @v1.post_config_save_boot(request)
        when ["GET",    %w[v1 processes]]        then @v1.get_processes(request)
        when ["GET",    %w[v1 interfaces]]       then @v1.get_interfaces(request)
        when ["GET",    %w[v1 queues]]           then @v1.get_queues(request)
        when ["GET",    %w[v1 policies]]         then @v1.get_policies(request)
        when ["GET",    %w[v1 secrets]]          then @v1.get_secrets(request)
        when ["GET",    %w[v1 runs]]             then @v1.get_runs(request)
        when ["GET",    %w[v1 tools]]            then @v1.get_tools(request)
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
        when method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "resume"
          @v1.post_run_resume(request, segments[2])
        when method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 artifacts] && segments[3] == "download"
          @v1.get_artifact_download(request, segments[2])
        else
          json_response(404, error: "no /v1 route for #{method} /#{segments.join('/')}")
        end
      end

      def check_admin(request)
        return nil if @admin_token.nil? || @admin_token.empty? # open mode

        provided = Auth.token_from(request)
        return json_response(401, error: "missing bearer token") if provided.nil? || provided.empty?
        return nil if Rack::Utils.secure_compare(provided, @admin_token)

        json_response(403, error: "admin token rejected")
      end

      def status_response
        json_response(200, status_payload)
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
