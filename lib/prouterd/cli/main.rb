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
            check  <file>                       Parse and validate a .prc config file
            render <file>                       Parse and print canonical config to stdout
            apply  <file> [--db PATH]           Validate + commit a .prc file as a new commit
            shell  [--db PATH] [--config FILE]  Start interactive router-style shell
            exec   "<cmd>" [--db PATH] [--config FILE]
                                                Run a single shell command and print result
            version                             Print version
            help                                Show this help

          Default DB path: var/prouterd.db (override via --db or PROUTERD_DB).

          Subsequent phases will add: trigger, replay, trace, webhooks.
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
        config_path, db_path, no_db = parse_runtime_options("shell")
        return 2 if config_path == :error

        store = open_store(db_path, no_db)
        return 1 if store == :error

        Prouterd::Shell::Shell.run(
          input: @stdin,
          output: @stdout,
          error: @stderr,
          initial_config_path: config_path,
          store: store
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

        config_path, db_path, no_db = parse_runtime_options("exec")
        return 2 if config_path == :error

        store = open_store(db_path, no_db)
        return 1 if store == :error

        session = Prouterd::Shell::Session.new(store: store)
        if config_path
          source = read_file(config_path)
          return 2 if source.nil?
          document = parse_with_diagnostics(source, config_path)
          return 1 if document.nil?
          result = Config::Validator.validate(document)
          unless result.valid?
            result.errors.each { |e| @stderr.puts "#{config_path}: #{e}" }
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
      def cmd_apply
        store = nil
        path = @argv.shift
        unless path
          @stderr.puts "prouter apply: missing file argument"
          return 2
        end

        _config_path, db_path, no_db = parse_runtime_options("apply")
        store = open_store(db_path, no_db)
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

      # Parses --config/-c, --db, --no-db options off @argv. Returns
      # [config_path, db_path, no_db_flag]. Returns :error in slot 0 on bad
      # option so callers can short-circuit.
      def parse_runtime_options(cmd)
        config_path = nil
        db_path = nil
        no_db = false
        until @argv.empty?
          case @argv.first
          when "--config", "-c"
            @argv.shift
            config_path = @argv.shift
            unless config_path
              @stderr.puts "prouter #{cmd}: --config requires a path"
              return [:error, nil, false]
            end
          when "--db"
            @argv.shift
            db_path = @argv.shift
            unless db_path
              @stderr.puts "prouter #{cmd}: --db requires a path"
              return [:error, nil, false]
            end
          when "--no-db"
            @argv.shift
            no_db = true
          else
            @stderr.puts "prouter #{cmd}: unknown option '#{@argv.first}'"
            return [:error, nil, false]
          end
        end
        [config_path, db_path, no_db]
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
