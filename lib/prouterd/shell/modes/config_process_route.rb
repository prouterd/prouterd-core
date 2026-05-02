require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router(config-route)#`  — body editor for a process route.
      #
      # Holds match conditions, on-failure policy, and the route's own
      # shutdown flag. Delegates field validation to Parser.
      class ConfigProcessRoute < Mode
        attr_reader :route

        def initialize(route_node)
          @route = route_node
        end

        def prompt_suffix
          "(config-route)#"
        end

        def commands
          {
            "show"   => :cmd_show,
            "no"     => :cmd_no,
            "do"     => :cmd_do,
            "commit" => :cmd_commit,
            "abort"  => :cmd_abort,
            "end"    => :cmd_end,
            "exit"   => :cmd_exit,
            "help"   => :cmd_help,
            "?"      => :cmd_help
          }
        end

        def apply_field(tokens, _session)
          apply_route_field(tokens)
          :handled
        end

        def cmd_do(tokens, session, out, err)
          run_do(tokens, session, out, err)
        end

        def cmd_commit(_tokens, _session, _out, _err); :commit; end
        def cmd_abort(_tokens, _session, _out, _err); :abort; end
        def cmd_end(_tokens, _session, _out, _err); :end; end
        def cmd_exit(_tokens, _session, _out, _err); :exit; end

        def cmd_no(tokens, _session = nil, _out = nil, _err = nil)
          expect_min_args(tokens, 2, "no <kind> [args]")
          kind = tokens[1].value
          case kind
          when "shutdown"
            expect_arg_count(tokens, 2, "no shutdown")
            @route.shutdown = false
          when "match"
            # Remove the most recently added match (best-effort); to remove a
            # specific one users can `abort` and re-enter with the desired set.
            raise CommandError, "no match conditions to remove" if @route.matches.empty?
            @route.matches.pop
          when "on-failure"
            expect_arg_count(tokens, 2, "no on-failure")
            @route.on_failure = "stop"
          else
            raise CommandError, "cannot 'no #{kind}' on a route"
          end
          :handled
        end

        def cmd_show(tokens, session, out, err)
          if tokens.length == 1
            raise CommandError, "syntax: show <target> [args]"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def apply_route_field(tokens)
          line = Prouterd::Config::Line.new(0, tokens)
          parser = Prouterd::Config::Parser.new([])
          parser.parse_process_route_field(@route, line)
        rescue Prouterd::Config::ParseError => e
          raise CommandError, e.message.sub(/\Aline \d+(?:, col \d+)?: /, "")
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            Process-route editor commands:
              match <path> <op> [val]   Add a match condition (eq, neq, gt, gte, lt, lte, exists, in)
              on-failure stop|continue  Set failure behavior
              shutdown / no shutdown    Toggle route state
              no <kind>                 Remove (no shutdown|match|on-failure)
              show <target>             Read-only inspection
              do <command>              Run a privileged command without leaving config
              commit                    Validate and apply candidate as running
              abort                     Discard candidate, return to privileged
              end                       Return to privileged, leave candidate intact
              exit                      Return to (config-process)#
              help, ?                   Show this help
          HELP
          :handled
        end
      end
    end
  end
end
