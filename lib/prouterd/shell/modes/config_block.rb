require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router(config-block)#`  — block field editor.
      #
      # All commands here are field directives (image, command, timeout,
      # retry policy, secret, input, output, network, shutdown, no shutdown)
      # that delegate to Config::Parser#parse_block_field for validation.
      class ConfigBlock < Mode
        attr_reader :block

        def initialize(block_node)
          @block = block_node
        end

        def prompt_suffix
          "(config-block)#"
        end

        def execute(tokens, session, out, err)
          head = tokens.first.value
          case head
          when "show"      then cmd_show(tokens, session, out, err)
          when "no"        then cmd_no(tokens)
          when "exit"      then :exit
          when "commit"    then :commit
          when "abort"     then :abort
          when "help", "?" then cmd_help(out)
          else
            apply_block_field(tokens)
            :handled
          end
        end

        def cmd_no(tokens)
          expect_min_args(tokens, 2, "no <kind> [args]")
          kind = tokens[1].value
          case kind
          when "shutdown"
            expect_arg_count(tokens, 2, "no shutdown")
            @block.shutdown = false
          when "secret"
            expect_arg_count(tokens, 3, "no secret <NAME>")
            removed = @block.secret_names.delete(tokens[2].value)
            raise CommandError, "no such secret reference '#{tokens[2].value}' on this block" unless removed
          when "command"
            expect_arg_count(tokens, 2, "no command")
            @block.command = nil
          when "retry"
            expect_arg_count(tokens, 3, "no retry policy")
            unless tokens[2].value == "policy"
              raise CommandError, "syntax: no retry policy"
            end
            @block.retry_policy_name = nil
          when "timeout"
            expect_arg_count(tokens, 2, "no timeout")
            @block.timeout_ms = nil
          when "input"
            expect_arg_count(tokens, 2, "no input")
            @block.input = nil
          when "output"
            expect_arg_count(tokens, 2, "no output")
            @block.output = nil
          else
            raise CommandError, "cannot 'no #{kind}' on a block"
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

        def apply_block_field(tokens)
          line = Prouterd::Config::Line.new(0, tokens)
          parser = Prouterd::Config::Parser.new([])
          parser.parse_block_field(@block, line)
        rescue Prouterd::Config::ParseError => e
          raise CommandError, e.message.sub(/\Aline \d+(?:, col \d+)?: /, "")
        end

        def cmd_help(out)
          out.puts <<~HELP
            Block editor commands:
              image <ref>              Set container image
              command <args...>        Set command override
              timeout <duration>       Set execution timeout (e.g. 120s, 2m)
              retry policy <name>      Bind a retry policy
              secret <NAME>            Add a secret reference (multiple allowed)
              input <context.path>     Set input context path
              output <context.path>    Set output context path
              network on|off           Toggle container networking
              shutdown / no shutdown   Toggle block state
              no <kind> [args]         Remove a field (no secret X, no command, no timeout, etc.)
              show <target>            Read-only inspection
              commit                   Validate and apply candidate as running
              abort                    Discard candidate, return to privileged
              exit                     Return to (config-process)#
              help, ?                  Show this help
          HELP
          :handled
        end
      end
    end
  end
end
