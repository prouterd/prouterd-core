require_relative "../mode"
require_relative "../command_line"
require_relative "../show"

module Prouterd
  module Shell
    module Modes
      # Generic editor sub-mode for "leaf" sections — router, secret, policy,
      # queue, interface — where the body is just a list of field directives.
      #
      # The Section mode delegates field validation back to Config::Parser's
      # public field-application methods, ensuring file-parser and shell never
      # disagree about what `image foo`, `timeout 30s`, `auth bearer ...`
      # mean. Each Section instance carries:
      #
      #   * @kind          symbol like :router, :secret, ...
      #   * @node          the AST node being edited (mutated in place)
      #   * @prompt_label  string after `(config-`
      class Section < Mode
        FIELD_APPLIERS = {
          router:    :apply_router_field,
          secret:    :apply_secret_field,
          policy:    :apply_policy_field,
          queue:     :apply_queue_field,
          interface: :parse_interface_field
        }.freeze

        def self.for_router(node);    new(:router,    node, "router")    end
        def self.for_secret(node);    new(:secret,    node, "secret")    end
        def self.for_policy(node);    new(:policy,    node, "policy")    end
        def self.for_queue(node);     new(:queue,     node, "queue")     end
        def self.for_interface(node); new(:interface, node, "interface") end

        attr_reader :node, :kind

        def initialize(kind, node, label)
          @kind = kind
          @node = node
          @label = label
        end

        def prompt_suffix
          "(config-#{@label})#"
        end

        def commands
          {
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

        # Sub-modes here act as field editors: any command not in `commands`
        # falls through to the file parser's field applier. That keeps
        # shell and `.prc` syntax in lockstep.
        def apply_field(tokens, _session)
          line = Prouterd::Config::Line.new(0, tokens)
          parser = Prouterd::Config::Parser.new([])
          method_name = FIELD_APPLIERS.fetch(@kind)
          parser.send(method_name, @node, line)
          :handled
        rescue Prouterd::Config::ParseError => e
          raise CommandError, e.message.sub(/\Aline \d+(?:, col \d+)?: /, "")
        end

        def cmd_show(tokens, session, out, err)
          if tokens.length == 1
            raise CommandError, "syntax: show <target> [args]"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def cmd_do(tokens, session, out, err)
          run_do(tokens, session, out, err)
        end

        def cmd_commit(_tokens, _session, _out, _err); :commit; end
        def cmd_abort(_tokens, _session, _out, _err); :abort; end
        def cmd_end(_tokens, _session, _out, _err); :end; end

        def cmd_exit(_tokens, _session, _out, _err)
          :exit
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            #{@label.capitalize} editor:
              <field> <value>...    Set a field (see file DSL §8 for valid fields)
              show <target>         Read-only inspection
              do <command>          Run a privileged command without leaving config
              commit                Validate and apply candidate as running
              abort                 Discard candidate, return to privileged
              end                   Return to privileged, leave candidate intact
              exit                  Return to (config)#
              help, ?               Show this help
          HELP
          :handled
        end
      end
    end
  end
end
