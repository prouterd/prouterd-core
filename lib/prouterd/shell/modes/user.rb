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
            "exit"   => :cmd_exit
          }
        end

        def cmd_enable(_tokens, _session, _out, _err)
          enter(Privileged.new)
        end

        # User-mode `show` is restricted to non-privileged targets.
        ALLOWED_SHOWS = %w[version status].freeze

        def cmd_show(tokens, session, out, err)
          target = tokens[1]&.value
          unless ALLOWED_SHOWS.include?(target)
            raise CommandError, "show #{target || '<missing>'} requires privileged mode (use 'enable')"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            User mode commands:
              enable           Enter privileged mode (#)
              show version     Print prouter version
              show status      Print runtime status
              help, ?          Show this help
              exit             Quit the shell
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
