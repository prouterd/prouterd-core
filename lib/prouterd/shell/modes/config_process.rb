require_relative "../mode"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # `process-router(config-process)#`  — process body editor.
      #
      # Field commands (`description`, `queue`, `shutdown`, `no shutdown`)
      # mutate the process node in place. Sub-section commands (`block X`,
      # `route a b`) push a child mode onto the stack.
      class ConfigProcess < Mode
        IDENT_RE = Prouterd::Config::Parser::IDENT_RE

        attr_reader :process

        def initialize(process_node)
          @process = process_node
        end

        def prompt_suffix
          "(config-process)#"
        end

        def commands
          {
            "block"  => :cmd_block,
            "route"  => :cmd_route,
            "no"     => :cmd_no,
            "show"   => :cmd_show,
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
          apply_process_field(tokens)
          :handled
        end

        def cmd_do(tokens, session, out, err)
          run_do(tokens, session, out, err)
        end

        def cmd_commit(_tokens, _session, _out, _err); :commit; end
        def cmd_abort(_tokens, _session, _out, _err); :abort; end
        def cmd_end(_tokens, _session, _out, _err); :end; end
        def cmd_exit(_tokens, _session, _out, _err); :exit; end

        def cmd_block(tokens, _session = nil, _out = nil, _err = nil)
          expect_arg_count(tokens, 2, "block <name>")
          name = check_identifier(tokens[1].value, "block name")
          existing = @process.blocks.find { |b| b.name == name }
          if existing
            enter(ConfigBlock.new(existing))
          else
            block = Prouterd::Config::AST::Block.new(name: name, line: 0)
            @process.blocks << block
            enter(ConfigBlock.new(block))
          end
        end

        # In process context, `route` is short or long form between blocks.
        # If the user supplies just `route from to`, we create a short-form
        # route record and STAY in process mode. To edit conditions, the user
        # types `route from to` again — we find the existing record and push
        # ConfigProcessRoute mode.
        #
        # The disambiguation rule: if a record with that (from, to) already
        # exists, push the editor mode. If not, create the short-form record
        # and stay. To go straight to long-form on creation, supply the route
        # then immediately re-enter to edit conditions.
        def cmd_route(tokens, _session = nil, _out = nil, _err = nil)
          expect_arg_count(tokens, 3, "route <from_block> <to_block>")
          from = check_identifier(tokens[1].value, "from-block name")
          to = check_identifier(tokens[2].value, "to-block name")
          existing = @process.routes.find { |r| r.from_block == from && r.to_block == to }
          if existing
            enter(ConfigProcessRoute.new(existing))
          else
            route = Prouterd::Config::AST::ProcessRoute.new(from_block: from, to_block: to, line: 0)
            @process.routes << route
            :handled
          end
        end

        def cmd_no(tokens, _session = nil, out = nil, _err = nil)
          expect_min_args(tokens, 2, "no <kind> ...")
          kind = tokens[1].value
          case kind
          when "shutdown"
            expect_arg_count(tokens, 2, "no shutdown")
            @process.shutdown = false
          when "block"
            expect_arg_count(tokens, 3, "no block <name>")
            removed = @process.blocks.reject! { |b| b.name == tokens[2].value }
            raise CommandError, "no such block '#{tokens[2].value}'" unless removed
            # also drop any routes touching this block
            @process.routes.reject! { |r| r.from_block == tokens[2].value || r.to_block == tokens[2].value }
          when "route"
            expect_arg_count(tokens, 4, "no route <from> <to>")
            from = tokens[2].value
            to = tokens[3].value
            removed = @process.routes.reject! { |r| r.from_block == from && r.to_block == to }
            raise CommandError, "no such route '#{from} -> #{to}'" unless removed
          when "description"
            expect_arg_count(tokens, 2, "no description")
            @process.description = nil
          when "queue"
            expect_arg_count(tokens, 2, "no queue")
            @process.queue_name = nil
          else
            raise CommandError, "cannot 'no #{kind}' here"
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

        def apply_process_field(tokens)
          line = Prouterd::Config::Line.new(0, tokens)
          parser = Prouterd::Config::Parser.new([])
          parser.apply_process_field(@process, line)
        rescue Prouterd::Config::ParseError => e
          raise CommandError, e.message.sub(/\Aline \d+(?:, col \d+)?: /, "")
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            Process editor commands:
              description <text>       Set process description (rest of line)
              queue <name>             Bind to a queue
              shutdown / no shutdown   Toggle process state
              block <name>             Add or edit a block (enters config-block)
              route <from> <to>        Add a route between blocks (re-issue to edit conditions)
              no <kind> [name]         Remove (no block|route|shutdown|description|queue)
              show <target>            Read-only inspection
              do <command>             Run a privileged command without leaving config
              commit                   Validate and apply candidate as running
              abort                    Discard candidate, return to privileged
              end                      Return to privileged, leave candidate intact
              exit                     Return to (config)#
              help, ?                  Show this help
          HELP
          :handled
        end

        def check_identifier(value, label)
          unless value.match?(IDENT_RE)
            raise CommandError, "invalid #{label} '#{value}' (must match #{IDENT_RE.source})"
          end
          value
        end
      end
    end
  end
end
