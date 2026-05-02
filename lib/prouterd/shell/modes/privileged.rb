require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router#`  — privileged mode. Full read access via `show`,
      # entry to config mode via `configure terminal`, and one-shot operations
      # like `load <file>`.
      #
      # `disable` returns to user mode; `exit` quits the shell.
      class Privileged < Mode
        PROMPT_SUFFIX = "#".freeze

        def prompt_suffix
          PROMPT_SUFFIX
        end

        def commands
          {
            "show"      => :cmd_show,
            "configure" => :cmd_configure,
            "load"      => :cmd_load,
            "disable"   => :cmd_disable,
            "exit"      => :cmd_exit,
            "help"      => :cmd_help,
            "?"         => :cmd_help
          }
        end

        def cmd_show(tokens, session, out, err)
          if tokens.length == 1
            raise CommandError, "syntax: show <target> [args]"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def cmd_configure(tokens, session, _out, _err)
          unless tokens.length == 2 && tokens[1].value == "terminal"
            raise CommandError, "syntax: configure terminal"
          end
          session.begin_candidate
          enter(Config.new)
        end

        def cmd_load(tokens, session, out, _err)
          unless tokens.length == 2
            raise CommandError, "syntax: load <file>"
          end
          path = tokens[1].value
          source = File.read(path)
          lines = Prouterd::Config::Lexer.tokenize(source)
          document = Prouterd::Config::Parser.parse(lines)
          result = Prouterd::Config::Validator.validate(document)
          unless result.valid?
            result.errors.each { |e| out.puts "load: #{path}: #{e}" }
            raise CommandError, "load failed: #{result.errors.length} error(s)"
          end
          session.replace_running(document)
          out.puts "Loaded #{path}: #{document.processes.length} processes, #{document.interfaces.length} interfaces"
          :handled
        rescue Errno::ENOENT
          raise CommandError, "no such file: #{tokens[1].value}"
        rescue Prouterd::Config::ConfigError => e
          raise CommandError, "load failed: #{e.message}"
        end

        def cmd_disable(_tokens, _session, _out, _err)
          :exit
        end

        def cmd_exit(_tokens, _session, _out, _err)
          :quit
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            Privileged mode commands:
              show <target>            See 'show ?' for available targets
              configure terminal       Enter config mode
              load <file>              Replace running config from .prc file
              disable                  Drop to user mode
              exit                     Quit the shell
              help, ?                  Show this help

            Show targets:
              version                  prouter version
              status                   shell session status
              running-config           current running config
              candidate-config         current candidate (only in config mode)
              processes / process N    list / detail
              interfaces / interface N
              policies / policy N
              queues / queue N
              secrets / secret N
              blocks process N         blocks in a process
              block process P B        single block detail
              routes [process N]       global routes (and optionally per-process)
              diff                     candidate vs running diff
          HELP
          :handled
        end
      end
    end
  end
end
