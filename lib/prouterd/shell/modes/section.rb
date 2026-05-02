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
          { "show" => :cmd_show, "exit" => :cmd_exit, "help" => :cmd_help, "?" => :cmd_help }
        end

        # Override execute: instead of dispatching only on a fixed table, fall
        # through to the parser's field-applier for any unrecognized command.
        # That keeps the dispatch DRY and matches the file syntax exactly.
        def execute(tokens, session, out, err)
          head = tokens.first.value
          case head
          when "show"     then cmd_show(tokens, session, out, err)
          when "exit"     then cmd_exit(tokens, session, out, err)
          when "commit"   then :commit
          when "abort"    then :abort
          when "help", "?" then cmd_help(tokens, session, out, err)
          else
            apply_field(tokens, session)
            :handled
          end
        end

        def apply_field(tokens, session)
          # Reconstruct a config Line so we can call the field applier. The
          # applier raises Config::ParseError on invalid input; we translate
          # to CommandError for shell display.
          line = Prouterd::Config::Line.new(0, tokens)
          parser = Prouterd::Config::Parser.new([])
          method_name = FIELD_APPLIERS.fetch(@kind)
          parser.send(method_name, @node, line)
        rescue Prouterd::Config::ParseError => e
          # Strip the "line N: " prefix; the shell knows the source.
          raise CommandError, e.message.sub(/\Aline \d+(?:, col \d+)?: /, "")
        end

        def cmd_show(tokens, session, out, err)
          if tokens.length == 1
            raise CommandError, "syntax: show <target> [args]"
          end
          Show.execute(tokens[1..], session, out, err)
          :handled
        end

        def cmd_exit(_tokens, _session, _out, _err)
          :exit
        end

        def cmd_help(_tokens, _session, out, _err)
          out.puts <<~HELP
            #{@label.capitalize} editor:
              <field> <value>...    Set a field (see file DSL §8 for valid fields)
              show <target>         Read-only inspection
              commit                Validate and apply candidate as running
              abort                 Discard candidate, return to privileged
              exit                  Return to (config)#
              help, ?               Show this help
          HELP
          :handled
        end
      end
    end
  end
end
