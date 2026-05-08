require_relative "../prouterd"
require_relative "bootstrap"
require_relative "daemon/lock"

module Prouterd
  module Daemon
    # `prouterd` daemon entry point.
    #
    # Replaces what used to be `prouter serve`. Runs the HTTP API + worker
    # pool + cron scheduler + recovery sweep in one process. State persists
    # in SQLite at --db (or PROUTERD_DB env). Graceful shutdown via SIGINT/
    # SIGTERM drains in-flight runs before stopping Puma.
    #
    # Usage:
    #   prouterd --db /var/lib/prouterd/prouterd.db
    #   prouterd --bind 0.0.0.0 --port 8080 --workers 8 --db ...
    #
    # Env vars: PROUTERD_ADMIN_TOKEN, PROUTERD_LOG_LEVEL, PROUTERD_SSL_CERT,
    #           PROUTERD_SSL_KEY, PROUTERD_MAX_BODY_BYTES, PROUTERD_RUNNER,
    #           PROUTERD_DB, PROUTERD_WEBHOOK_RATE, etc. (see README).
    class Main
      include Bootstrap

      def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
        new(argv, stdin, stdout, stderr).run
      end

      def initialize(argv, stdin, stdout, stderr)
        @argv = argv.dup
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
      end

      def run
        opts = parse_args
        return opts if opts.is_a?(Integer)

        # Delegate the help and version short-circuits before doing any DB work.
        return cmd_help if opts[:help]
        return cmd_version if opts[:version]

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error
        unless store
          @stderr.puts "prouterd: requires --db (the daemon needs persistent state)"
          return 2
        end

        # Single-daemon mutex on the DB path. Two daemons against one
        # DB would race jobs and Recovery.sweep would mark each other's
        # in-flight runs as failed. Released automatically by the
        # kernel on process exit.
        db_path = opts[:db_path] || ENV["PROUTERD_DB"] || Prouterd::Storage::DB::DEFAULT_PATH
        begin
          @lock_fd = Lock.acquire(db_path)
        rescue LockError => e
          @stderr.puts "prouterd: #{e.message}"
          return 3
        end

        logger = Prouterd::Logger.build(@stdout)
        store.logger = logger
        logger.info("daemon starting",
                    facility: "DAEMON", mnemonic: "STARTING",
                    bind: opts[:bind], port: opts[:port],
                    db: opts[:db_path], workers: opts[:workers],
                    runner: opts[:runner_kind])

        in_flight = Prouterd::Runtime::InFlightRegistry.new
        metrics = Prouterd::API::Metrics.new(in_flight: in_flight)
        runner = build_runner(opts[:runner_kind], in_flight: in_flight)
        return 1 if runner == :error

        admin_token = ENV["PROUTERD_ADMIN_TOKEN"]
        if admin_token.nil? || admin_token.empty?
          logger.warn("PROUTERD_ADMIN_TOKEN not set; /v1/* endpoints are open",
                      facility: "DAEMON", mnemonic: "OPEN_AUTH")
        end

        # Crash recovery: any run/step left in `running`/`queued` from a previous
        # daemon process must be marked failed before we accept new traffic.
        Prouterd::Runtime::Recovery.sweep(store.db, logger: logger)

        # Persistent job queue: webhook / /v1 trigger / scheduler enqueue jobs
        # here instead of spawning ad-hoc threads, so daemon crashes recover.
        jobs = Prouterd::Storage::Repositories::Jobs.new(store.db)

        # MCP pool — one persistent JSON-RPC session per
        # `interface mcp <name>` declaration. Spawned with the
        # current running config; reconciliation on `config apply`
        # is wired through the events bus. Shut down inside the
        # `ensure` block below so daemon shutdown SIGTERMs each
        # subprocess gracefully. Built before the worker pool so
        # workers see it on first claim.
        secret_resolver = Prouterd::Runtime::EnvSecretResolver.new
        mcp_pool = Prouterd::Iface::Mcp::Pool.new(
          secret_resolver: secret_resolver, logger: logger
        )
        begin
          mcp_pool.start_or_reconcile(store.load_running)
        rescue StandardError => e
          logger.warn("mcp pool initial reconcile failed",
                      facility: "MCP", mnemonic: "RECONCILE_ERR",
                      error: e.class.name, message: e.message)
        end

        worker_pool = Prouterd::Runtime::WorkerPool.new(
          store: store, runner: runner, in_flight: in_flight, metrics: metrics,
          workers: opts[:workers], logger: logger,
          mcp_pool: mcp_pool
        )
        worker_pool.run

        scheduler = Prouterd::Runtime::Scheduler.new(
          store: store, runner: runner, logger: logger,
          in_flight: in_flight, metrics: metrics, jobs: jobs
        )
        scheduler.run

        rate_limiter = Prouterd::API::RateLimiter.from_env

        # Templates inside running blocks can reach the daemon's own
        # bind URL via {{system.url}} — used e.g. by HTTP self-call
        # patterns (see examples/13_slack_approval.prc). https when SSL
        # is configured, http otherwise.
        scheme = ENV["PROUTERD_SSL_CERT"].to_s.empty? ? "http" : "https"
        system_url = "#{scheme}://#{opts[:bind]}:#{opts[:port]}"

        # When --console-dir points at the SPA repo, the daemon serves
        # /console/* at same-origin. Cookie auth (set by /v1/login)
        # rides every browser request without CORS plumbing.
        console_dir = nil
        if opts[:console_dir]
          unless File.directory?(opts[:console_dir])
            @stderr.puts "prouterd: --console-dir '#{opts[:console_dir]}' is not a directory"
            return 2
          end
          console_dir = File.expand_path(opts[:console_dir])
        end

        app = Prouterd::API::App.new(
          store: store, runner: runner, logger: logger,
          in_flight: in_flight, metrics: metrics,
          admin_token: admin_token, jobs: jobs, rate_limiter: rate_limiter,
          system_url: system_url,
          console_dir: console_dir,
          mcp_pool: mcp_pool
        )
        app.start_storage_probe

        begin
          Prouterd::API::Server.run(
            app: app, bind: opts[:bind], port: opts[:port], logger: logger,
            in_flight: in_flight,
            ssl_cert: ENV["PROUTERD_SSL_CERT"], ssl_key: ENV["PROUTERD_SSL_KEY"]
          )
        ensure
          app.stop_storage_probe
          scheduler.stop
          worker_pool.stop
          mcp_pool.stop
          logger.info("daemon stopped", facility: "DAEMON", mnemonic: "STOPPED")
        end
        0
      ensure
        store&.db&.close if store && store != :error
      end

      private

      def parse_args
        opts = {
          bind: Prouterd::API::Server::DEFAULT_BIND,
          port: Prouterd::API::Server::DEFAULT_PORT,
          db_path: nil,
          no_db: false,
          runner_kind: default_runner_kind,
          workers: Prouterd::Runtime::WorkerPool::DEFAULT_WORKERS,
          help: false,
          version: false
        }
        until @argv.empty?
          case @argv.first
          when "--bind", "-b"
            @argv.shift
            opts[:bind] = @argv.shift or return missing_arg("--bind")
          when "--port", "-p"
            @argv.shift
            port_str = @argv.shift or return missing_arg("--port")
            opts[:port] = Integer(port_str) rescue (return invalid_arg("--port must be an integer"))
          when "--db"
            @argv.shift
            opts[:db_path] = @argv.shift or return missing_arg("--db")
          when "--no-db"
            @argv.shift
            opts[:no_db] = true
          when "--runner"
            @argv.shift
            opts[:runner_kind] = @argv.shift or return missing_arg("--runner")
          when "--workers"
            @argv.shift
            n = @argv.shift or return missing_arg("--workers")
            opts[:workers] = Integer(n) rescue (return invalid_arg("--workers must be an integer"))
          when "--console-dir"
            @argv.shift
            opts[:console_dir] = @argv.shift or return missing_arg("--console-dir")
          when "--help", "-h"
            @argv.shift
            opts[:help] = true
          when "--version", "-v"
            @argv.shift
            opts[:version] = true
          else
            @stderr.puts "prouterd: unknown option '#{@argv.first}'"
            return 2
          end
        end
        opts
      end

      def missing_arg(opt)
        @stderr.puts "prouterd: #{opt} requires a value"
        2
      end

      def invalid_arg(msg)
        @stderr.puts "prouterd: #{msg}"
        2
      end

      def cmd_help
        @stdout.puts <<~USAGE
          Usage: prouterd [options]

          Long-running daemon: HTTP webhook listener + cron scheduler +
          worker pool. State persists in SQLite at --db (or env PROUTERD_DB).

          Options:
            --bind ADDR         bind address (default: #{Prouterd::API::Server::DEFAULT_BIND})
            --port N            bind port (default: #{Prouterd::API::Server::DEFAULT_PORT})
            --db PATH           SQLite path (env: PROUTERD_DB) — REQUIRED
            --no-db             in-memory mode (rejected; daemon needs state)
            --runner KIND       real (default) | shell | stub (env: PROUTERD_RUNNER)
            --workers N         worker pool size (default: #{Prouterd::Runtime::WorkerPool::DEFAULT_WORKERS})
            --console-dir PATH  serve operator SPA from PATH at /console/*
                                (single-process deploy; cookie auth)
            --version, -v       print version
            --help, -h          show this help

          Env vars (see README for full list):
            PROUTERD_ADMIN_TOKEN     bearer token for /v1/* admin endpoints
            PROUTERD_LOG_LEVEL       debug|info|warn|error|fatal
            PROUTERD_SSL_CERT/KEY    PEM cert+key paths for HTTPS
            PROUTERD_MAX_BODY_BYTES  request body cap (default 1 MB)
            PROUTERD_WEBHOOK_RATE    MAX/WINDOW per-iface webhook rate limit

          For one-shot operator commands (check, render, apply, shell, exec,
          trigger, replay, cancel, diff, cleanup, trace), use `prouter`.
        USAGE
        0
      end

      def cmd_version
        @stdout.puts "prouterd #{Prouterd::VERSION}"
        0
      end
    end
  end
end
