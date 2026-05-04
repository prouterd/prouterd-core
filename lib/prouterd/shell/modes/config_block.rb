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
          apply_block_field(tokens)
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
            @block.shutdown = false
          when "secret"
            expect_arg_count(tokens, 3, "no secret <NAME>")
            removed = @block.secret_names.delete(tokens[2].value)
            raise CommandError, "no such secret reference '#{tokens[2].value}' on this block" unless removed
          when "interface"
            expect_arg_count(tokens, 2, "no interface")
            @block.interface_ref = nil
          when "retry"
            expect_arg_count(tokens, 3, "no retry policy")
            unless tokens[2].value == "policy"
              raise CommandError, "syntax: no retry policy"
            end
            @block.retry_policy_name = nil
          when "timeout"
            expect_arg_count(tokens, 2, "no timeout")
            @block.timeout_ms = nil
          when "contract"
            expect_arg_count(tokens, 2, "no contract")
            @block.contract_name = nil
          else
            # Per-call args live in @block.type_fields keyed by their DSL
            # keyword. `no <field>` clears them by removing the entry.
            if @block.type_fields.key?(kind)
              @block.type_fields.delete(kind)
            else
              raise CommandError, "cannot 'no #{kind}' on a block"
            end
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

        def cmd_help(_tokens, _session, out, _err)
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
              do <command>             Run a privileged command without leaving config
              commit                   Validate and apply candidate as running
              abort                    Discard candidate, return to privileged
              end                      Return to privileged, leave candidate intact
              exit                     Return to (config-process)#
              help, ?                  Show this help
          HELP
          :handled
        end
      end
    end
  end
end
