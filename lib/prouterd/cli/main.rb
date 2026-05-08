require_relative "../../prouterd"
require_relative "../bootstrap"
require "stringio"

module Prouterd
  module CLI
    # Entry point for the `prouter` binary — operator CLI client.
    #
    # One-shot commands: check / render / apply / shell / exec / trigger /
    # trace / replay / cancel / diff / cleanup / version / help.
    #
    # The long-running daemon (HTTP + cron + worker pool) is a separate
    # binary, `prouterd` (see lib/prouterd/daemon.rb).
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
        command = @argv.shift
        case command
        when "check"             then cmd_check
        when "render"            then cmd_render
        when "shell"             then cmd_shell
        when "exec"              then cmd_exec
        when "apply"             then cmd_apply
        when "validate"          then cmd_validate
        when "trigger"           then cmd_trigger
        when "trace"             then cmd_trace
        when "replay"            then cmd_replay
        when "resume"            then cmd_resume
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
            check    <file>                    Parse and validate a .prc config file (alias: validate)
            validate <file> [--against running] Lint a .prc, or semantic-diff vs the running config
            render   <file>                    Parse and print canonical config to stdout
            apply   <file>                     Validate + commit a .prc file as a new commit
            trigger process <name> input <file>
                                               Synchronously run a process for the given event
            replay  run <uid>                  Re-execute a previous run with the same event + commit
            resume  run <uid>            [--value <json>] Resume a paused run with the given output value
            resume  run-by-thread <id>   [--value <json>] Resume the latest paused run carrying that thread_id
            cancel  run <uid>                  Soft-cancel an in-flight run
            trace   event <file>               Static routing analysis (no execution)
            diff    <file>                     Show changes if file were applied vs running config
            cleanup --older-than 30d           Delete terminal runs older than threshold
            shell                              Start interactive router-style shell
            exec    "<cmd>"                    Run a single shell command and print result
            version                            Print version
            help                               Show this help

          Common options for shell/exec/apply/trigger:
            --db PATH        SQLite path (default: var/prouterd.db, env: PROUTERD_DB)
            --no-db          Skip persistence (in-memory)
            --config FILE    Load this .prc file as the running config
            --runner KIND    docker (default) | stub (env: PROUTERD_RUNNER)

          The long-running daemon is a separate binary: `prouterd`.
          Run `prouterd --help` for daemon options.
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
        batch_size = Prouterd::ControlPlane::Cleanup::DEFAULT_BATCH_SIZE

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
          when "--batch-size"
            @argv.shift
            n = @argv.shift or return missing_arg("cleanup", "--batch-size")
            batch_size = Integer(n) rescue (return invalid_arg("cleanup", "--batch-size must be a positive integer"))
            return invalid_arg("cleanup", "--batch-size must be a positive integer") if batch_size < 1
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
          dry_run: dry_run,
          batch_size: batch_size
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
        if machine_output?
          steps = repo.list_steps(new_run.id).map do |s|
            { block: s.block_name, status: s.status, attempt: s.attempt,
              duration_ms: s.duration_ms, error_type: s.error_type }
          end
          @stdout.puts JSON.dump(run_id: new_run.uid, replay_of: run_uid,
                                  status: new_run.status, steps: steps,
                                  error: new_run.error_summary)
        else
          @stdout.puts "Replayed #{run_uid} as #{new_run.uid} (#{new_run.status})"
          repo.list_steps(new_run.id).each do |s|
            duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
            @stdout.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
          end
          @stdout.puts "  error: #{new_run.error_summary}" if new_run.error_summary
        end

        new_run.status == "success" ? 0 : 1
      rescue Prouterd::Shell::ShellError, Prouterd::Runtime::TriggerError => e
        @stderr.puts "prouter replay: #{e.message}"
        1
      ensure
        store&.db&.close if store && store != :error
      end

      # `prouter resume run <uid> [--value <json>]` — resume a paused
      # run, supplying the JSON output for the paused block. Defaults
      # to {} if --value is omitted.
      #
      # `prouter resume run-by-thread <thread_id> [--value <json>]` —
      # resolve to the most recent paused run carrying that thread_id
      # (Phase 38h). Useful when an external system (Slack interaction
      # webhook, signed callback) only knows the thread_id, not the
      # internal run uid. Errors with a clear message if no paused run
      # matches.
      def cmd_resume
        unless @argv.length >= 2 && %w[run run-by-thread].include?(@argv[0])
          @stderr.puts "prouter resume: usage: resume run <uid> [--value <json>] [--db PATH] [--runner KIND]"
          @stderr.puts "                or:    resume run-by-thread <thread_id> [--value <json>]"
          return 2
        end
        mode = @argv[0]
        key  = @argv[1]
        @argv = @argv[2..]

        value = nil
        if @argv[0] == "--value" && @argv[1]
          begin
            value = JSON.parse(@argv[1])
          rescue JSON::ParserError => e
            @stderr.puts "prouter resume: invalid JSON for --value: #{e.message}"
            return 2
          end
          @argv = @argv[2..]
        end

        opts = parse_runtime_options("resume")
        return 2 if opts == :error

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error
        unless store
          @stderr.puts "prouter resume: requires --db (resumes act on a persisted run)"
          return 2
        end

        runner = build_runner(opts[:runner_kind])
        return 1 if runner == :error

        repo = Prouterd::Storage::Repositories::Runs.new(store.db)
        run =
          if mode == "run"
            repo.get_run_by_uid(key)
          else
            paused = repo.list_runs(limit: 200, status: "paused", thread_id: key)
            paused.first  # list_runs orders DESC by id → first is latest
          end
        unless run
          @stderr.puts "prouter resume: no #{mode == 'run' ? 'run' : 'paused run for thread'} '#{key}'"
          return 1
        end
        run_uid = run.uid
        unless run.process_config_commit_id
          @stderr.puts "prouter resume: run '#{run_uid}' has no pinned commit; cannot resume"
          return 1
        end

        commit = store.get_commit(run.process_config_commit_id)
        unless commit
          @stderr.puts "prouter resume: pinned commit ##{run.process_config_commit_id} is gone"
          return 1
        end
        document = Config::Parser.parse(Config::Lexer.tokenize(commit.rendered_config))

        orchestrator = Prouterd::Runtime::Orchestrator.new(db: store.db, runner: runner)
        finished = orchestrator.resume_run(run_uid, document, value: value)

        if machine_output?
          steps = repo.list_steps(finished.id).map do |s|
            { block: s.block_name, status: s.status, attempt: s.attempt,
              duration_ms: s.duration_ms, error_type: s.error_type }
          end
          @stdout.puts JSON.dump(run_id: finished.uid, status: finished.status,
                                 steps: steps, error: finished.error_summary)
        else
          @stdout.puts "Resumed #{run_uid} (#{finished.status})"
          repo.list_steps(finished.id).each do |s|
            duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
            @stdout.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
          end
          @stdout.puts "  error: #{finished.error_summary}" if finished.error_summary
        end

        finished.status == "success" ? 0 : 1
      rescue Prouterd::Runtime::TriggerError => e
        @stderr.puts "prouter resume: #{e.message}"
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
        emit_run_summary(run, repo)

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

      # Emits a run summary in machine-readable JSON when stdout is piped,
      # human-friendly table form when on a TTY. Same shape across
      # `trigger`, `replay`, etc.
      def emit_run_summary(run, repo)
        steps = repo.list_steps(run.id).map do |s|
          { block: s.block_name, status: s.status, attempt: s.attempt,
            duration_ms: s.duration_ms, error_type: s.error_type }
        end
        if machine_output?
          @stdout.puts JSON.dump(
            run_id: run.uid, status: run.status, steps: steps,
            error: run.error_summary
          )
        else
          @stdout.puts "Run #{run.uid}: #{run.status}"
          steps.each do |s|
            duration = s[:duration_ms] ? "#{s[:duration_ms]}ms" : "-"
            @stdout.puts "  %-25s %-9s %s" % [s[:block], s[:status], duration]
          end
          @stdout.puts "  error: #{run.error_summary}" if run.error_summary
        end
      end

      # True when our @stdout is a non-TTY (pipe, file, etc.) — caller
      # should emit JSON instead of human-formatted tables. The IO may
      # be a StringIO under test; respond_to? guard avoids NoMethodError
      # on doubles that don't bother to respond.
      def machine_output?
        return true unless @stdout.respond_to?(:tty?)

        !@stdout.tty?
      end

      # Phase 36e: `prouter validate <file> --against running [--db PATH]`.
      # Parses + validates the file just like `check`, then computes a
      # semantic diff against the currently running config — what
      # interfaces / processes / routes / secrets / policies / queues
      # add, remove, or change. Useful as a pre-apply review.
      def cmd_validate
        store = nil
        path = @argv.shift
        unless path
          @stderr.puts "prouter validate: usage: validate <file> [--against running [--db PATH]]"
          return 2
        end

        # `prouter validate <file>` without `--against` is the lint /
        # dry-run form: parse + validate the file against itself, no
        # daemon state touched. Equivalent to `prouter check <file>`,
        # surfaced under the more-canonical `validate` verb so docs +
        # CI hooks have the obvious command to call.
        if @argv.empty?
          @argv.unshift(path)
          return cmd_check
        end

        # The only `--against` value we support today is `running`. Accept
        # the long-form to leave room for `startup` / a specific commit
        # later without breaking the CLI surface.
        unless @argv.first == "--against"
          @stderr.puts "prouter validate: missing --against running"
          return 2
        end
        @argv.shift
        target = @argv.shift
        unless target == "running"
          @stderr.puts "prouter validate: only `--against running` is supported"
          return 2
        end

        opts = parse_runtime_options("validate")
        return 2 if opts == :error

        source = read_file(path)
        return 2 if source.nil?
        candidate = parse_with_diagnostics(source, path)
        return 1 if candidate.nil?

        result = Config::Validator.validate(candidate)
        unless result.valid?
          @stderr.puts "Validation failed:"
          result.errors.each { |e| @stderr.puts "  #{path}: #{e}" }
          return 1
        end

        store = open_store(opts[:db_path], opts[:no_db])
        return 1 if store == :error
        running = store ? store.load_running : Config::AST::Document.new

        diff = Util::SemanticDiff.diff(running, candidate)
        emit_validate_diff(path, diff)
        diff.empty? ? 0 : 0
      ensure
        store&.db&.close if store && store != :error
      end

      def emit_validate_diff(path, diff)
        if machine_output?
          @stdout.puts JSON.dump(file: path, diff: diff.to_json_payload, total_changes: diff.total)
          return
        end

        if diff.empty?
          @stdout.puts "#{path}: no semantic changes vs running config."
          return
        end

        @stdout.puts "#{path}: #{diff.total} change(s) vs running config:"
        sections = {
          "interfaces added"   => diff.interfaces_added,
          "interfaces removed" => diff.interfaces_removed,
          "interfaces changed" => diff.interfaces_changed,
          "processes added"    => diff.processes_added,
          "processes removed"  => diff.processes_removed,
          "processes changed"  => diff.processes_changed,
          "routes added"       => diff.routes_added,
          "routes removed"     => diff.routes_removed,
          "secrets added"      => diff.secrets_added,
          "secrets removed"    => diff.secrets_removed,
          "policies added"     => diff.policies_added,
          "policies removed"   => diff.policies_removed,
          "policies changed"   => diff.policies_changed,
          "queues added"       => diff.queues_added,
          "queues removed"     => diff.queues_removed,
          "queues changed"     => diff.queues_changed
        }
        sections.each do |label, items|
          next if items.empty?

          @stdout.puts "  #{label}:"
          items.each { |c| @stdout.puts "    #{c.name}  (#{c.reason})" }
        end
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

      # `default_runner_kind`, `open_store`, `build_runner` provided by
      # Prouterd::Bootstrap mixin so `prouter` and `prouterd` parse and
      # validate runtime options identically.

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
        base_dir = path && File.exist?(path) ? File.dirname(File.expand_path(path)) : nil
        Config::Parser.parse(lines, base_dir: base_dir)
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
                     when "webhook" then "#{iface.type_fields['method'] || '?'} #{iface.type_fields['path'] || '?'}"
                     when "cron"    then "schedule=#{iface.type_fields['schedule'].inspect}"
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
