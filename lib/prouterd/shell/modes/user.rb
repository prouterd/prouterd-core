# frozen_string_literal: true

require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router>`  — read-only entry mode.
      #
      # Privileged commands require explicit `enable` to proceed. From here
      # `exit` quits the shell entirely.
      class User < Mode
        PROMPT_SUFFIX = ">".freeze

        def prompt_suffix
          PROMPT_SUFFIX
        end

        def commands
          {
            "enable" => :cmd_enable,
            "show"   => :cmd_show,
            "help"   => :cmd_help,
            "?"      => :cmd_help,
            "exit"   => :cmd_exit,
            "logout" => :cmd_exit,
            "quit"   => :cmd_exit
          }
        end

        def cmd_enable(_tokens, _session, _out, _err)
          enter(Privileged.new)
        end

        # User-mode `show` is restricted to harmless inspection targets. The
        # canonical set is small; abbreviated forms are expanded against it
        # (so `sh ver` / `sh st` / `sh cl` resolve like router).
        ALLOWED_SHOWS = %w[version status clock].freeze

        def cmd_show(tokens, session, out, err)
          target = tokens[1]&.value
          expanded = expand_allowed(target)
          unless expanded
            raise CommandError, "show #{target || '<missing>'} requires privileged mode (use 'enable')"
          end
          new_tokens = tokens.dup
          new_tokens[1] = rebuild_head_token(tokens[1], expanded)
          Show.execute(new_tokens[1..], session, out, err)
          :handled
        end

        def expand_allowed(target)
          return nil if target.nil?
          return target if ALLOWED_SHOWS.include?(target)

          matches = ALLOWED_SHOWS.select { |t| t.length > target.length && t.start_with?(target) }
          matches.length == 1 ? matches.first : nil
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            User mode commands:
              enable              Enter privileged mode (#)
              show version        Print prouter version
              show status         Print runtime status
              show clock          Print current UTC time
              help, ?             Show this help (or any command followed by `?`)
              exit, logout, quit  Quit the shell
          HELP
          :handled
        end

        def cmd_exit(_tokens, _session, _out, _err)
          :quit
        end
      end
    end
  end
end
