require_relative "../../prouterd"
require "stringio"

module Prouterd
  module CLI
    # Entry point for the `prouter` binary.
    #
    # Phase 1+2 commands:
    #   prouter check  <file>           — parse + validate, exit 0/1
    #   prouter render <file>           — parse + emit canonical config
    #   prouter shell  [--config FILE]  — interactive router-style shell
    #   prouter exec   "<command>"      — run a single command non-interactively
    #   prouter version                 — print version
    #   prouter help                    — print usage
    class Main
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
        command = @argv.shift
        case command
        when "check"             then cmd_check
        when "render"            then cmd_render
        when "shell"             then cmd_shell
        when "exec"              then cmd_exec
        when "apply"             then cmd_apply
        when "trigger"           then cmd_trigger
        when "trace"             then cmd_trace
        when "replay"            then cmd_replay
        when "serve"             then cmd_serve
        when "cancel"            then cmd_cancel
        when "diff"              then cmd_diff
        when "cleanup"           then cmd_cleanup
        when "version", "--version", "-v" then cmd_version
        when "help", "--help", "-h", nil  then cmd_help
        else
          @stderr.puts "prouter: unknown command '#{command}'"
          @stderr.puts
          cmd_help
          2
        end
      end

      private

      def cmd_help
        @stdout.puts <<~USAGE
          Usage: prouter <command> [args]

          Commands:
            check   <file>                     Parse and validate a .prc config file
            render  <file>                     Parse and print canonical config to stdout
            apply   <file>                     Validate + commit a .prc file as a new commit
            trigger process <name> input <file>
                                               Synchronously run a process for the given event
            replay  run <uid>                  Re-execute a previous run with the same event + commit
            cancel  run <uid>                  Soft-cancel an in-flight run
            trace   event <file>               Static routing analysis (no execution)
            diff    <file>                     Show changes if file were applied vs running config
            cleanup --older-than 30d           Delete terminal runs older than threshold
            serve   [--bind ADDR] [--port N]   Start HTTP daemon (webhooks + cron + /v1 API)
            shell                              Start interactive router-style shell
            exec    "<cmd>"                    Run a single shell command and print result
            version                            Print version
            help                               Show this help

          Common options for shell/exec/apply/trigger:
            --db PATH        SQLite path (default: var/prouterd.db, env: PROUTERD_DB)
            --no-db          Skip persistence (in-memory)
            --config FILE    Load this .prc file as the running config
            --runner KIND    docker (default) | stub (env: PROUTERD_RUNNER)

          Subsequent phases will add: replay, trace, webhooks.
        USAGE
        0
      end

      def cmd_version
        @stdout.puts "prouter #{Prouterd::VERSION}"
        0
      end

      def cmd_check
        path = @argv.shift
        unless path
          @stderr.puts "prouter check: missing file argument"
          return 2
        end

        source = read_file(path)
        return 2 if source.nil?

        document = parse_with_diagnostics(source, path)
        return 1 if document.nil?

        result = Config::Validator.validate(document)
        report_check(document, result, path)
        result.valid? ? 0 : 1
      end

      def cmd_render
        path = @argv.shift
        unless path
          @stderr.puts "prouter render: missing file argument"
          return 2
        end

        source = read_file(path)
        return 2 if source.nil?

        document = parse_with_diagnostics(source, path)
        return 1 if document.nil?

        @stdout.print Config::Renderer.render(document)
        0
      end

      def cmd_shell
        store = nil
        opts = parse_runtime_options("shell")
        return 2 if opts == :error

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error

        runner = build_runner(opts[:runner_kind])
        return 1 if runner == :error

        session = Prouterd::Shell::Session.new(store: store, runner: runner)
        Prouterd::Shell::Shell.run(
          session: session,
          input: @stdin,
          output: @stdout,
          error: @stderr,
          initial_config_path: opts[:config_path]
        )
      rescue Prouterd::Shell::ShellError => e
        @stderr.puts "prouter shell: #{e.message}"
        1
      ensure
        store&.db&.close if store && store != :error
      end

      def cmd_exec
        store = nil
        command = @argv.shift
        unless command
          @stderr.puts "prouter exec: missing command string"
          return 2
        end

        opts = parse_runtime_options("exec")
        return 2 if opts == :error

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error

        runner = build_runner(opts[:runner_kind])
        return 1 if runner == :error

        session = Prouterd::Shell::Session.new(store: store, runner: runner)
        if opts[:config_path]
          source = read_file(opts[:config_path])
          return 2 if source.nil?
          document = parse_with_diagnostics(source, opts[:config_path])
          return 1 if document.nil?
          result = Config::Validator.validate(document)
          unless result.valid?
            result.errors.each { |e| @stderr.puts "#{opts[:config_path]}: #{e}" }
            return 1
          end
          session.replace_running(document)
        end

        shell = Prouterd::Shell::Shell.new(
          session: session,
          input: StringIO.new,
          output: @stdout,
          error: @stderr,
          interactive: false,
          banner: false
        )
        shell.execute_one(command)
      ensure
        store&.db&.close if store && store != :error
      end

      # Standalone non-interactive `apply <file> [--db PATH]` — validates the
      # file, persists it as a new commit, and updates running pointer.
      # `prouter serve` — start the HTTP daemon (Puma) so external systems
      # can POST events to webhook interfaces. Blocks until SIGINT/SIGTERM.
      def cmd_serve
        store = nil
        bind = Prouterd::API::Server::DEFAULT_BIND
        port = Prouterd::API::Server::DEFAULT_PORT
        db_path = nil
        runner_kind = default_runner_kind
        no_db = false
        workers = Prouterd::Runtime::WorkerPool::DEFAULT_WORKERS

        until @argv.empty?
          case @argv.first
          when "--bind", "-b"
            @argv.shift
            bind = @argv.shift or return missing_arg("serve", "--bind")
          when "--port", "-p"
            @argv.shift
            port_str = @argv.shift or return missing_arg("serve", "--port")
            port = Integer(port_str) rescue (return invalid_arg("serve", "--port must be an integer"))
          when "--db"
            @argv.shift
            db_path = @argv.shift or return missing_arg("serve", "--db")
          when "--no-db"
            @argv.shift
            no_db = true
          when "--runner"
            @argv.shift
            runner_kind = @argv.shift or return missing_arg("serve", "--runner")
          when "--workers"
            @argv.shift
            n = @argv.shift or return missing_arg("serve", "--workers")
            workers = Integer(n) rescue (return invalid_arg("serve", "--workers must be an integer"))
          else
            @stderr.puts "prouter serve: unknown option '#{@argv.first}'"
            return 2
          end
        end

        store = open_store(db_path, no_db)
        return 1 if store == :error
        unless store
          @stderr.puts "prouter serve: requires --db (the daemon needs persistent state)"
          return 2
        end

        # Build a fresh runner that knows about the daemon's in-flight registry
        # — so DockerRunner can report active container IDs for hard cancel.
        in_flight = Prouterd::Runtime::InFlightRegistry.new
        metrics = Prouterd::API::Metrics.new(in_flight: in_flight)
        runner = build_runner(runner_kind, in_flight: in_flight)
        return 1 if runner == :error

        admin_token = ENV["PROUTERD_ADMIN_TOKEN"]
        if admin_token.nil? || admin_token.empty?
          @stdout.puts "prouter serve: WARNING — PROUTERD_ADMIN_TOKEN not set; /v1/* endpoints are open"
        end

        # Crash recovery: any run/step left in `running`/`queued` from a
        # previous daemon process must be marked failed before we accept
        # new traffic. Otherwise replay/show would still see them as live.
        Prouterd::Runtime::Recovery.sweep(store.db, output: @stdout)

        # Persistent job queue: the daemon's worker pool drains it. Webhook /
        # /v1 trigger / scheduler enqueue jobs here instead of spawning ad-hoc
        # threads so daemon crashes can be recovered.
        jobs = Prouterd::Storage::Repositories::Jobs.new(store.db)

        worker_pool = Prouterd::Runtime::WorkerPool.new(
          store: store, runner: runner, in_flight: in_flight, metrics: metrics,
          workers: workers, output: @stdout
        )
        worker_pool.run

        # Cron scheduler runs alongside the HTTP listener. Started before
        # serve so any cron whose next_time is "now" can fire immediately.
        scheduler = Prouterd::Runtime::Scheduler.new(
          store: store, runner: runner, output: @stdout,
          in_flight: in_flight, metrics: metrics, jobs: jobs
        )
        scheduler.run

        rate_limiter = Prouterd::API::RateLimiter.from_env

        app = Prouterd::API::App.new(
          store: store, runner: runner,
          in_flight: in_flight, metrics: metrics,
          admin_token: admin_token, jobs: jobs, rate_limiter: rate_limiter
        )
        begin
          Prouterd::API::Server.run(
            app: app, bind: bind, port: port, output: @stdout,
            in_flight: in_flight
          )
        ensure
          scheduler.stop
          worker_pool.stop
        end
        0
      ensure
        store&.db&.close if store && store != :error
      end

      def missing_arg(cmd, opt)
        @stderr.puts "prouter #{cmd}: #{opt} requires a value"
        2
      end

      def invalid_arg(cmd, msg)
        @stderr.puts "prouter #{cmd}: #{msg}"
        2
      end

      # `prouter cleanup --older-than 30d [--dry-run] [--db PATH]`
      # Removes terminal runs older than the threshold along with their
      # cascading steps/logs/artifacts and on-disk artifact files. Active
      # runs are never touched. Config commits are kept (audit trail).
      def cmd_cleanup
        store = nil
        older_than_str = nil
        dry_run = false
        db_path = nil
        no_db = false

        until @argv.empty?
          case @argv.first
          when "--older-than"
            @argv.shift
            older_than_str = @argv.shift or return missing_arg("cleanup", "--older-than")
          when "--dry-run"
            @argv.shift
            dry_run = true
          when "--db"
            @argv.shift
            db_path = @argv.shift or return missing_arg("cleanup", "--db")
          when "--no-db"
            @argv.shift
            no_db = true
          else
            @stderr.puts "prouter cleanup: unknown option '#{@argv.first}'"
            return 2
          end
        end

        unless older_than_str
          @stderr.puts "prouter cleanup: --older-than is required (e.g. 30d, 12h, 7d)"
          return 2
        end

        seconds = parse_retention_window(older_than_str)
        return 2 unless seconds

        store = open_store(db_path, no_db)
        return 1 if store == :error
        unless store
          @stderr.puts "prouter cleanup: requires --db"
          return 2
        end

        result = Prouterd::ControlPlane::Cleanup.sweep(
          store.db,
          older_than: seconds,
          dry_run: dry_run
        )

        verb = dry_run ? "would delete" : "deleted"
        @stdout.puts "Cleanup #{verb}:"
        @stdout.puts "  runs:           #{result.runs}"
        @stdout.puts "  run_steps:      #{result.steps}"
        @stdout.puts "  run_logs:       #{result.logs}"
        @stdout.puts "  artifact rows:  #{result.artifacts}"
        @stdout.puts "  artifact files: #{result.artifact_files}"
        0
      ensure
        store&.db&.close if store && store != :error
      end

      def parse_retention_window(input)
        m = /\A(\d+)([smhd])\z/.match(input.to_s)
        unless m
          @stderr.puts "prouter cleanup: invalid --older-than '#{input}' (expected e.g. 30d, 12h, 1800s)"
          return nil
        end
        n = m[1].to_i
        case m[2]
        when "s" then n
        when "m" then n * 60
        when "h" then n * 3600
        when "d" then n * 86_400
        end
      end

      # `prouter cancel run <uid>` — soft-cancel a run from the CLI.
      def cmd_cancel
        store = nil
        unless @argv.length >= 2 && @argv[0] == "run"
          @stderr.puts "prouter cancel: usage: cancel run <uid> [--db PATH]"
          return 2
        end
        uid = @argv[1]
        @argv = @argv[2..]

        opts = parse_runtime_options("cancel")
        return 2 if opts == :error
        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error
        unless store
          @stderr.puts "prouter cancel: requires --db"
          return 2
        end

        repo = Prouterd::Storage::Repositories::Runs.new(store.db)
        run = repo.get_run_by_uid(uid)
        unless run
          @stderr.puts "prouter cancel: no such run '#{uid}'"
          return 1
        end
        if %w[success failed canceled].include?(run.status)
          @stderr.puts "prouter cancel: run '#{uid}' is already #{run.status}"
          return 1
        end

        finished_at = Time.now.utc.iso8601(3)
        repo.update_run(run.id, status: "canceled", finished_at: finished_at, error_summary: "canceled by operator")
        repo.list_steps(run.id).each do |s|
          next if %w[success failed canceled timeout skipped].include?(s.status)

          repo.update_step(s.id, status: "canceled", finished_at: finished_at,
                                 error_type: "canceled", error_message: "canceled by operator")
        end
        @stdout.puts "Cancelled run #{uid}."
        0
      ensure
        store&.db&.close if store && store != :error
      end

      # `prouter diff <file> [--db PATH]` — show what would change if the file
      # were applied. Compares against the running pointer in --db (or the
      # provided --config).
      def cmd_diff
        store = nil
        path = @argv.shift
        unless path
          @stderr.puts "prouter diff: usage: diff <file> [--db PATH | --config FILE]"
          return 2
        end

        opts = parse_runtime_options("diff")
        return 2 if opts == :error

        document_target = parse_with_diagnostics(File.read(path), path)
        return 1 if document_target.nil?

        running_doc =
          if opts[:config_path]
            parsed = parse_with_diagnostics(File.read(opts[:config_path]), opts[:config_path])
            return 1 if parsed.nil?
            parsed
          else
            store = open_store(opts[:db_path], opts[:no_db])
            return 1 if store == :error
            return 1 if store.nil?
            store.load_running
          end

        a = Prouterd::Config::Renderer.render(running_doc).split("\n", -1)
        b = Prouterd::Config::Renderer.render(document_target).split("\n", -1)

        diff_lines = Prouterd::Shell::Show.simple_diff(a, b)
        if diff_lines.empty?
          @stdout.puts "No changes."
          return 0
        end
        diff_lines.each { |l| @stdout.puts(l) }
        0
      rescue Errno::ENOENT => e
        @stderr.puts "prouter diff: #{e.message}"
        2
      ensure
        store&.db&.close if store && store != :error
      end

      # `prouter replay run <uid>` — re-runs a previous run.
      # `prouter replay run <uid> from <block>` — replays from a chosen block.
      def cmd_replay
        store = nil
        from_block = nil
        unless @argv.length >= 2 && @argv[0] == "run"
          @stderr.puts "prouter replay: usage: replay run <uid> [from <block>] [--db PATH] [--runner KIND]"
          return 2
        end
        run_uid = @argv[1]
        @argv = @argv[2..]
        if @argv[0] == "from" && @argv[1]
          from_block = @argv[1]
          @argv = @argv[2..]
        end

        opts = parse_runtime_options("replay")
        return 2 if opts == :error

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error
        unless store
          @stderr.puts "prouter replay: requires --db (replays must be persisted)"
          return 2
        end

        runner = build_runner(opts[:runner_kind])
        return 1 if runner == :error

        session = Prouterd::Shell::Session.new(store: store, runner: runner)
        new_run = if from_block
                    session.replay_from(run_uid, from_block)
                  else
                    session.replay(run_uid)
                  end

        repo = Prouterd::Storage::Repositories::Runs.new(store.db)
        @stdout.puts "Replayed #{run_uid} as #{new_run.uid} (#{new_run.status})"
        repo.list_steps(new_run.id).each do |s|
          duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
          @stdout.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
        end
        @stdout.puts "  error: #{new_run.error_summary}" if new_run.error_summary

        new_run.status == "success" ? 0 : 1
      rescue Prouterd::Shell::ShellError, Prouterd::Runtime::TriggerError => e
        @stderr.puts "prouter replay: #{e.message}"
        1
      ensure
        store&.db&.close if store && store != :error
      end

      # `prouter trace event <file> [--interface NAME]` — static routing
      # analysis without executing any blocks. Reads config from --config or
      # from the running pointer in --db.
      def cmd_trace
        store = nil
        unless @argv.length >= 2 && @argv[0] == "event"
          @stderr.puts "prouter trace: usage: trace event <file> [--interface NAME] [--config FILE | --db PATH]"
          return 2
        end
        event_path = @argv[1]
        @argv = @argv[2..]

        interface_name = nil
        while %w[--interface -i].include?(@argv.first)
          @argv.shift
          interface_name = @argv.shift
          unless interface_name
            @stderr.puts "prouter trace: --interface requires a name"
            return 2
          end
        end

        opts = parse_runtime_options("trace")
        return 2 if opts == :error

        document =
          if opts[:config_path]
            source = read_file(opts[:config_path])
            return 2 if source.nil?
            parsed = parse_with_diagnostics(source, opts[:config_path])
            return 1 if parsed.nil?
            parsed
          else
            store = open_store(opts[:db_path], opts[:no_db])
            return 1 if store == :error
            return 1 if store.nil?
            store.load_running
          end

        event = JSON.parse(File.read(event_path))
        result = Prouterd::Runtime::Tracer.trace(document, event, interface_name: interface_name)
        @stdout.print Prouterd::Runtime::TracerRenderer.render(result)
        result.error ? 1 : 0
      rescue Errno::ENOENT => e
        @stderr.puts "prouter trace: #{e.message}"
        2
      rescue JSON::ParserError => e
        @stderr.puts "prouter trace: event file is not valid JSON: #{e.message}"
        2
      ensure
        store&.db&.close if store && store != :error
      end

      # Standalone non-interactive `trigger process <name> input <file>`. Always
      # synchronous; prints a step-by-step summary and exits with the run status.
      def cmd_trigger
        store = nil
        unless @argv.length >= 4 && @argv[0] == "process" && @argv[2] == "input"
          @stderr.puts "prouter trigger: usage: trigger process <name> input <file> [--db PATH] [--runner docker|stub]"
          return 2
        end
        process_name = @argv[1]
        input_path = @argv[3]
        @argv = @argv[4..]

        opts = parse_runtime_options("trigger")
        return 2 if opts == :error

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error

        runner = build_runner(opts[:runner_kind])
        return 1 if runner == :error

        document =
          if opts[:config_path]
            source = read_file(opts[:config_path])
            return 2 if source.nil?
            parsed = parse_with_diagnostics(source, opts[:config_path])
            return 1 if parsed.nil?
            parsed
          elsif store
            store.load_running
          else
            @stderr.puts "prouter trigger: no config available (use --config or have a running commit in --db)"
            return 2
          end

        validation = Config::Validator.validate(document)
        unless validation.valid?
          validation.errors.each { |e| @stderr.puts "config invalid: #{e}" }
          return 1
        end

        unless store
          @stderr.puts "prouter trigger: requires --db (runs must be persisted)"
          return 2
        end

        orchestrator = Prouterd::Runtime::Orchestrator.new(
          db: store.db,
          runner: runner
        )

        run = orchestrator.trigger(
          document,
          process_name,
          input_event: JSON.parse(File.read(input_path)),
          commit_id: store.running_commit&.id
        )

        repo = Prouterd::Storage::Repositories::Runs.new(store.db)
        @stdout.puts "Run #{run.uid}: #{run.status}"
        repo.list_steps(run.id).each do |s|
          duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
          @stdout.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
        end
        @stdout.puts "  error: #{run.error_summary}" if run.error_summary

        run.status == "success" ? 0 : 1
      rescue Errno::ENOENT => e
        @stderr.puts "prouter trigger: #{e.message}"
        2
      rescue JSON::ParserError => e
        @stderr.puts "prouter trigger: input file is not valid JSON: #{e.message}"
        2
      rescue Prouterd::Runtime::TriggerError => e
        @stderr.puts "prouter trigger: #{e.message}"
        1
      ensure
        store&.db&.close if store && store != :error
      end

      def cmd_apply
        store = nil
        path = @argv.shift
        unless path
          @stderr.puts "prouter apply: missing file argument"
          return 2
        end

        opts = parse_runtime_options("apply")
        return 2 if opts == :error
        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error

        source = read_file(path)
        return 2 if source.nil?

        document = parse_with_diagnostics(source, path)
        return 1 if document.nil?

        result = Config::Validator.validate(document)
        unless result.valid?
          @stderr.puts "Validation failed:"
          result.errors.each { |e| @stderr.puts "  #{path}: #{e}" }
          return 1
        end

        if store
          commit = store.commit(document, author: ENV["USER"], message: "apply #{File.basename(path)}")
          @stdout.puts "Applied #{path} as commit #{commit.id} (#{commit.short_checksum})."
        else
          @stdout.puts "Validated #{path}, but no DB attached — not persisted."
        end
        0
      ensure
        store&.db&.close if store && store != :error
      end

      # Parses --config/-c, --db, --no-db, --runner options off @argv. Returns
      # a Hash of resolved options or :error on bad option.
      def parse_runtime_options(cmd)
        opts = { config_path: nil, db_path: nil, no_db: false, runner_kind: default_runner_kind }
        until @argv.empty?
          case @argv.first
          when "--config", "-c"
            @argv.shift
            opts[:config_path] = @argv.shift
            unless opts[:config_path]
              @stderr.puts "prouter #{cmd}: --config requires a path"
              return :error
            end
          when "--db"
            @argv.shift
            opts[:db_path] = @argv.shift
            unless opts[:db_path]
              @stderr.puts "prouter #{cmd}: --db requires a path"
              return :error
            end
          when "--no-db"
            @argv.shift
            opts[:no_db] = true
          when "--runner"
            @argv.shift
            opts[:runner_kind] = @argv.shift
            unless opts[:runner_kind]
              @stderr.puts "prouter #{cmd}: --runner requires a kind (docker|stub)"
              return :error
            end
          else
            @stderr.puts "prouter #{cmd}: unknown option '#{@argv.first}'"
            return :error
          end
        end
        opts
      end

      def default_runner_kind
        ENV["PROUTERD_RUNNER"] || "docker"
      end

      # Opens a ConfigStore at the resolved path, or returns nil if --no-db
      # was given. Returns :error on failure.
      def open_store(explicit_path, no_db)
        return nil if no_db

        path = explicit_path || ENV["PROUTERD_DB"] || Prouterd::Storage::DB::DEFAULT_PATH
        db = Prouterd::Storage::DB.open(path)
        Prouterd::ControlPlane::ConfigStore.new(db)
      rescue SQLite3::Exception, Prouterd::Storage::StorageError => e
        @stderr.puts "prouter: cannot open DB at #{path}: #{e.message}"
        :error
      end

      # Build the per-execution-type runner map. The default mode (`real`)
      # asks each registered Plugin to instantiate its runner — adding a new
      # runner type is purely a plugin file, no edits here. `stub` swaps in
      # the test-fixture runner for every type. `shell` is a docker-less
      # convenience: route the docker plugin's slot to ShellRunner so blocks
      # without docker still execute (they'll fail without an `image`).
      def build_runner(kind, in_flight: nil)
        opts = { in_flight: in_flight }
        case kind
        when nil, "real", "docker"
          Prouterd::Runner::Registry.all.each_with_object({}) do |plugin, h|
            h[plugin.type_name] = plugin.build_runner(opts)
          end
        when "shell"
          shell = Prouterd::Runner::ShellRunner.new
          Prouterd::Runner::Registry.types.each_with_object({}) do |type, h|
            h[type] = shell
          end
        when "stub"
          stub = Prouterd::Runner::StubRunner.new
          Prouterd::Runner::Registry.types.each_with_object({}) do |type, h|
            h[type] = stub
          end
        else
          allowed = (%w[real shell stub] + Prouterd::Runner::Registry.types).uniq.join("|")
          @stderr.puts "prouter: unknown runner kind '#{kind}' (#{allowed})"
          :error
        end
      rescue LoadError, StandardError => e
        @stderr.puts "prouter: cannot initialize runner '#{kind}': #{e.message}"
        :error
      end

      def read_file(path)
        File.read(path)
      rescue Errno::ENOENT
        @stderr.puts "prouter: no such file: #{path}"
        nil
      rescue SystemCallError => e
        @stderr.puts "prouter: cannot read #{path}: #{e.message}"
        nil
      end

      def parse_with_diagnostics(source, path)
        lines = Config::Lexer.tokenize(source)
        Config::Parser.parse(lines)
      rescue Config::ConfigError => e
        @stderr.puts "#{path}: #{e.message}"
        nil
      end

      def report_check(document, result, path)
        if result.valid?
          @stdout.puts "Config valid."
        else
          @stdout.puts "Config invalid."
        end
        @stdout.puts

        @stdout.puts "Router:"
        @stdout.puts "  #{document.router&.name || '(missing)'}"
        @stdout.puts

        @stdout.puts "Interfaces:"
        if document.interfaces.empty?
          @stdout.puts "  (none)"
        else
          document.interfaces.each do |iface|
            extras = case iface.type
                     when "webhook" then "#{iface.method || '?'} #{iface.path || '?'}"
                     when "cron"    then "schedule=#{iface.schedule.inspect}"
                     else                ""
                     end
            @stdout.puts "  #{iface.name} #{iface.type} #{extras}".rstrip
          end
        end
        @stdout.puts

        @stdout.puts "Processes:"
        if document.processes.empty?
          @stdout.puts "  (none)"
        else
          document.processes.each do |process|
            @stdout.puts "  #{process.name}"
            @stdout.puts "    blocks: #{process.blocks.length}"
            @stdout.puts "    routes: #{process.routes.length}"
            entry = entry_blocks_for(process)
            @stdout.puts "    entry blocks: #{entry.empty? ? '(none)' : entry.join(', ')}"
          end
        end
        @stdout.puts

        @stdout.puts "Policies:"
        @stdout.puts(document.policies.empty? ? "  (none)" : document.policies.map { |p| "  #{p.name}" })
        @stdout.puts

        @stdout.puts "Queues:"
        @stdout.puts(document.queues.empty? ? "  (none)" : document.queues.map { |q| "  #{q.name}" })
        @stdout.puts

        unless result.errors.empty?
          @stdout.puts "Errors:"
          result.errors.each { |e| @stdout.puts "  #{path}: #{e}" }
          @stdout.puts
        end

        @stdout.puts "Warnings:"
        if result.warnings.empty?
          @stdout.puts "  none"
        else
          result.warnings.each { |w| @stdout.puts "  #{path}: #{w}" }
        end
      end

      def entry_blocks_for(process)
        names = process.blocks.map(&:name)
        with_incoming = process.routes.map(&:to_block).uniq
        names - with_incoming
      end
    end
  end
end
