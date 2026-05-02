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
            "copy"      => :cmd_copy,
            "rollback"  => :cmd_rollback,
            "trigger"   => :cmd_trigger,
            "trace"     => :cmd_trace,
            "replay"    => :cmd_replay,
            "cancel"    => :cmd_cancel,
            "diff"      => :cmd_diff,
            "disable"   => :cmd_disable,
            "exit"      => :cmd_exit,
            "logout"    => :cmd_exit,
            "quit"      => :cmd_exit,
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
          unless tokens.length == 2 && match_keyword?(tokens[1].value, "terminal")
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
          unless tokens.length == 2 && match_keyword?(tokens[1].value, "memory")
            raise CommandError, "syntax: write memory"
          end
          perform_write_memory(session, out)
        end

        # `copy running-config startup-config` — modern router-OS spelling for
        # `write memory`. Both forms persist the current running config as
        # the startup config; both accept abbreviated keywords (`co ru st`).
        def cmd_copy(tokens, session, out, _err)
          unless tokens.length == 3 &&
                 match_keyword?(tokens[1].value, "running-config") &&
                 match_keyword?(tokens[2].value, "startup-config")
            raise CommandError, "syntax: copy running-config startup-config"
          end
          perform_write_memory(session, out)
        end

        def perform_write_memory(session, out)
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
          unless tokens.length == 3 && match_keyword?(tokens[1].value, "commit")
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

        # `trigger process <name> input <file>` — synchronously executes the
        # process for the given input event, prints a step-by-step summary,
        # and returns when the run terminates (success or failed).
        def cmd_trigger(tokens, session, out, _err)
          unless tokens.length == 5 &&
                 match_keyword?(tokens[1].value, "process") &&
                 match_keyword?(tokens[3].value, "input")
            raise CommandError, "syntax: trigger process <name> input <file>"
          end
          process_name = tokens[2].value
          input_path = tokens[4].value

          event = parse_input_file(input_path)
          run = session.orchestrator.trigger(
            session.running_config,
            process_name,
            input_event: event,
            commit_id: session.store&.running_commit&.id
          )
          render_run_summary(run, session, out)
          :handled
        rescue Errno::ENOENT
          raise CommandError, "no such input file: #{tokens[4].value}"
        rescue JSON::ParserError => e
          raise CommandError, "input file is not valid JSON: #{e.message}"
        rescue Prouterd::Runtime::TriggerError, Prouterd::Shell::ShellError => e
          raise CommandError, e.message
        end

        def parse_input_file(path)
          source = File.read(path)
          JSON.parse(source)
        end

        # `replay run <uid>` or `replay run <uid> from <block>`.
        # Without `from`: re-execute from scratch with the original event +
        # config commit. With `from`: seed context from the step's captured
        # input and start at that block.
        def cmd_replay(tokens, session, out, _err)
          new_run =
            if tokens.length == 3 && match_keyword?(tokens[1].value, "run")
              session.replay(tokens[2].value)
            elsif tokens.length == 5 &&
                  match_keyword?(tokens[1].value, "run") &&
                  match_keyword?(tokens[3].value, "from")
              session.replay_from(tokens[2].value, tokens[4].value)
            else
              raise CommandError, "syntax: replay run <uid> [from <block>]"
            end

          out.puts "Replayed #{tokens[2].value} as #{new_run.uid} (#{new_run.status})"
          steps = Prouterd::Storage::Repositories::Runs.new(session.store.db).list_steps(new_run.id)
          steps.each do |s|
            duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
            out.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
          end
          out.puts "  error: #{new_run.error_summary}" if new_run.error_summary
          :handled
        rescue Prouterd::Shell::ShellError, Prouterd::Runtime::TriggerError => e
          raise CommandError, e.message
        end

        # `diff <file> running-config` — show what would change if `file` were
        # applied. Operates entirely in-memory (no candidate side-effects).
        def cmd_diff(tokens, session, out, _err)
          unless tokens.length == 3 && match_keyword?(tokens[2].value, "running-config")
            raise CommandError, "syntax: diff <file> running-config"
          end
          Show.diff_file_against_running([tokens[1].value], session, out)
          :handled
        end

        # `cancel run <uid>` — soft cancel: marks the run + any non-terminal
        # steps as canceled. The orchestrator polls run.status between levels
        # and aborts. In-flight containers complete naturally (or hit timeout).
        def cmd_cancel(tokens, session, out, _err)
          unless tokens.length == 3 && match_keyword?(tokens[1].value, "run")
            raise CommandError, "syntax: cancel run <uid>"
          end
          uid = tokens[2].value

          unless session.store
            raise CommandError, "no DB attached; cancel requires --db"
          end

          repo = Prouterd::Storage::Repositories::Runs.new(session.store.db)
          run = repo.get_run_by_uid(uid)
          raise CommandError, "no such run '#{uid}'" unless run
          if %w[success failed canceled].include?(run.status)
            raise CommandError, "run '#{uid}' is already #{run.status}"
          end

          finished_at = Time.now.utc.iso8601(3)
          repo.update_run(
            run.id,
            status: "canceled",
            finished_at: finished_at,
            error_summary: "canceled by operator"
          )
          repo.list_steps(run.id).each do |s|
            next if %w[success failed canceled timeout skipped].include?(s.status)

            repo.update_step(
              s.id,
              status: "canceled",
              finished_at: finished_at,
              error_type: "canceled",
              error_message: "canceled by operator"
            )
          end

          out.puts "Cancelled run #{uid}. In-flight blocks will finish naturally."
          :handled
        end

        # `trace event <file> [interface <name>]` — static analysis. Walks the
        # routing decisions for the given event without running any blocks,
        # so users can predict pipeline behavior before triggering.
        def cmd_trace(tokens, session, out, _err)
          unless tokens.length >= 3 && match_keyword?(tokens[1].value, "event")
            raise CommandError, "syntax: trace event <file> [interface <name>]"
          end
          event_path = tokens[2].value
          iface = nil
          if tokens.length == 5 && match_keyword?(tokens[3].value, "interface")
            iface = tokens[4].value
          elsif tokens.length != 3
            raise CommandError, "syntax: trace event <file> [interface <name>]"
          end

          event = JSON.parse(File.read(event_path))
          result = Prouterd::Runtime::Tracer.trace(session.running_config, event, interface_name: iface)
          out.print Prouterd::Runtime::TracerRenderer.render(result)
          :handled
        rescue Errno::ENOENT
          raise CommandError, "no such event file: #{tokens[2].value}"
        rescue JSON::ParserError => e
          raise CommandError, "event file is not valid JSON: #{e.message}"
        end

        def render_run_summary(run, session, out)
          steps = Prouterd::Storage::Repositories::Runs.new(session.store.db).list_steps(run.id)
          out.puts "Run #{run.uid}: #{run.status}"
          steps.each do |s|
            duration = s.duration_ms ? "#{s.duration_ms}ms" : "-"
            out.puts "  %-25s %-9s %s" % [s.block_name, s.status, duration]
          end
          out.puts "  error: #{run.error_summary}" if run.error_summary
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
              configure terminal       Enter config mode (abbrev: conf t)
              load <file>              Replace running config from .prc file (no commit)
              apply <file>             Load + commit a .prc file as a new commit
              write memory             Save current running as startup-config
              copy running-config startup-config
                                       Same as `write memory` (modern router-OS spelling)
              rollback commit <id>     Move running pointer back to an earlier commit
              disable                  Drop to user mode
              exit, logout, quit       Quit the shell
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
