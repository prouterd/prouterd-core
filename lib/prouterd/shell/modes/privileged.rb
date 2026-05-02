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
            "apply"     => :cmd_apply,
            "write"     => :cmd_write,
            "rollback"  => :cmd_rollback,
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

        # `apply <file>` — load file, validate, COMMIT as a new persisted commit.
        # Equivalent to `configure terminal` + replace + `commit` in one step,
        # but driven from a file. Without a store, falls through to a load
        # plus a synthetic commit so the running config still updates.
        def cmd_apply(tokens, session, out, _err)
          unless tokens.length == 2
            raise CommandError, "syntax: apply <file>"
          end
          path = tokens[1].value
          source = File.read(path)
          document = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(source))
          result = Prouterd::Config::Validator.validate(document)
          unless result.valid?
            result.errors.each { |e| out.puts "apply: #{path}: #{e}" }
            raise CommandError, "apply failed: #{result.errors.length} error(s)"
          end

          if session.store
            commit = session.store.commit(document, author: ENV["USER"], message: "apply #{File.basename(path)}")
            session.replace_running(document)
            session.instance_variable_set(:@last_commit, commit)
            out.puts "Applied #{path} as commit #{commit.id} (#{commit.short_checksum})"
          else
            session.replace_running(document)
            out.puts "Applied #{path} (no DB attached; not persisted)"
          end
          :handled
        rescue Errno::ENOENT
          raise CommandError, "no such file: #{tokens[1].value}"
        rescue Prouterd::Config::ConfigError => e
          raise CommandError, "apply failed: #{e.message}"
        end

        # `write memory` — bless current running as startup config.
        def cmd_write(tokens, session, out, _err)
          unless tokens.length == 2 && tokens[1].value == "memory"
            raise CommandError, "syntax: write memory"
          end
          unless session.store
            raise CommandError, "no DB attached; nothing to persist (start shell with --db)"
          end
          commit = session.write_memory
          out.puts "Startup configuration saved (commit #{commit.id})."
          :handled
        rescue Prouterd::ControlPlane::ConfigStoreError => e
          raise CommandError, e.message
        end

        # `rollback commit <id>` — point running at an earlier commit.
        def cmd_rollback(tokens, session, out, _err)
          unless tokens.length == 3 && tokens[1].value == "commit"
            raise CommandError, "syntax: rollback commit <id>"
          end
          unless session.store
            raise CommandError, "no DB attached; rollback requires --db"
          end
          id = Integer(tokens[2].value)
          commit = session.rollback_to(id)
          out.puts "Rolled back running configuration to commit #{commit.id} (#{commit.short_checksum})."
          :handled
        rescue ArgumentError
          raise CommandError, "commit id must be an integer"
        rescue Prouterd::ControlPlane::ConfigStoreError, Prouterd::Shell::ShellError => e
          raise CommandError, e.message
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
              show <target>            See list below
              configure terminal       Enter config mode
              load <file>              Replace running config from .prc file (no commit)
              apply <file>             Load + commit a .prc file as a new commit
              write memory             Save current running as startup-config
              rollback commit <id>     Move running pointer back to an earlier commit
              disable                  Drop to user mode
              exit                     Quit the shell
              help, ?                  Show this help

            Show targets:
              version                  prouter version
              status                   shell session status
              running-config           current running config
              startup-config           saved startup config (after `write memory`)
              candidate-config         current candidate (only in config mode)
              commits                  history of commits (newest first)
              commit <id>              specific commit detail
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
