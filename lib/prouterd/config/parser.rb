require_relative "../util/duration_parser"
require_relative "../iface/registry"

module Prouterd
  module Config
    # Builds an AST::Document from a stream of Lines produced by Lexer.
    #
    # The parser is line-oriented and section-recursive: each top-level keyword
    # opens a section that ends with an explicit `exit`. The only exception is
    # short-form process routes (e.g. `route extract enrich`) which have no body.
    class Parser
      IDENT_RE = /\A[A-Za-z_][A-Za-z0-9_-]*\z/.freeze
      ENV_NAME_RE = /\A[A-Z_][A-Z0-9_]*\z/.freeze
      HTTP_METHODS = Iface::Plugins::Webhook::HTTP_METHODS
      BACKOFF_TYPES = AST::Policy::BACKOFF_TYPES

      ROUTE_BODY_HEADS = %w[match on-failure shutdown no].freeze

      def self.parse(lines)
        new(lines).parse
      end

      def initialize(lines)
        @lines = lines
        @pos = 0
      end

      def parse
        doc = AST::Document.new

        while (line = current_line)
          head = line.head.value
          case head
          when "router"
            raise ParseError.new("router already defined", line: line.number) if doc.router
            doc.router = parse_router(line)
          when "secret"    then doc.secrets << parse_secret(line)
          when "policy"    then doc.policies << parse_policy(line)
          when "queue"     then doc.queues << parse_queue(line)
          when "interface" then doc.interfaces << parse_interface(line)
          when "process"   then doc.processes << parse_process(line)
          when "route"     then doc.global_routes << parse_global_route(line)
          when "contract"  then doc.contracts << parse_contract(line)
          when "exit"
            raise ParseError.new("unexpected 'exit' at top level", line: line.number)
          else
            raise ParseError.new("unknown top-level directive '#{head}'", line: line.number)
          end
        end

        doc
      end

      private

      # ----- top-level sections -----

      def parse_router(header)
        expect_token_count(header, 2, "router <name>")
        name = expect_identifier(header.tokens[1], "router name")
        node = AST::Router.new(name: name, line: header.number)
        advance

        each_body_line("router #{name}") do |line|
          apply_router_field(node, line)
        end

        node
      end

      # Apply a single field directive line to a Router node. Used by the
      # parser's section walker AND by the interactive shell's config-router
      # mode — a single source of truth for valid fields and validation.
      def apply_router_field(node, line)
        head = line.head.value
        case head
        when "version"
          expect_token_count(line, 2, "version <integer>")
          node.version = expect_integer(line.tokens[1], "version")
        when "hostname"
          expect_token_count(line, 2, "hostname <name>")
          node.hostname = expect_word_or_string(line.tokens[1], "hostname")
        else
          raise ParseError.new("unknown directive '#{head}' in router", line: line.number)
        end
      end

      def parse_secret(header)
        expect_token_count(header, 2, "secret <name>")
        name = expect_env_name(header.tokens[1], "secret name")
        node = AST::Secret.new(name: name, line: header.number)
        advance

        each_body_line("secret #{name}") do |line|
          apply_secret_field(node, line)
        end

        node
      end

      SECRET_SOURCES = %w[env file].freeze

      def apply_secret_field(node, line)
        head = line.head.value
        case head
        when "source"
          expect_min_tokens(line, 3, "source <#{SECRET_SOURCES.join('|')}> <ref>")
          kind = line.tokens[1].value
          unless SECRET_SOURCES.include?(kind)
            raise ParseError.new(
              "unsupported secret source '#{kind}' (allowed: #{SECRET_SOURCES.join(', ')})",
              line: line.number
            )
          end
          expect_token_count(line, 3, "source #{kind} <ref>")
          node.source_type = kind
          node.source_value = if kind == "env"
                                expect_env_name(line.tokens[2], "env variable")
                              else
                                expect_word_or_string(line.tokens[2], "file path")
                              end
        else
          raise ParseError.new("unknown directive '#{head}' in secret", line: line.number)
        end
      end

      def parse_policy(header)
        expect_token_count(header, 2, "policy <name>")
        name = expect_identifier(header.tokens[1], "policy name")
        node = AST::Policy.new(name: name, line: header.number)
        advance

        each_body_line("policy #{name}") do |line|
          apply_policy_field(node, line)
        end

        node
      end

      def apply_policy_field(node, line)
        head = line.head.value
        case head
        when "retry"
          apply_policy_retry(node, line)
        when "timeout"
          expect_token_count(line, 2, "timeout <duration>")
          node.timeout_ms = expect_duration(line.tokens[1], "timeout")
        else
          raise ParseError.new("unknown directive '#{head}' in policy", line: line.number)
        end
      end

      def apply_policy_retry(node, line)
        expect_min_tokens(line, 3, "retry <field> <value>")
        field = line.tokens[1].value
        case field
        when "attempts"
          expect_token_count(line, 3, "retry attempts <integer>")
          value = expect_integer(line.tokens[2], "retry attempts")
          raise ParseError.new("retry attempts must be >= 1", line: line.number) if value < 1
          node.retry_attempts = value
        when "backoff"
          expect_token_count(line, 3, "retry backoff <fixed|linear|exponential>")
          kind = expect_word_or_string(line.tokens[2], "retry backoff")
          unless BACKOFF_TYPES.include?(kind)
            raise ParseError.new("invalid backoff '#{kind}' (allowed: #{BACKOFF_TYPES.join(', ')})", line: line.number)
          end
          node.retry_backoff = kind
        when "initial-delay"
          expect_token_count(line, 3, "retry initial-delay <duration>")
          node.retry_initial_delay_ms = expect_duration(line.tokens[2], "retry initial-delay")
        when "max-delay"
          expect_token_count(line, 3, "retry max-delay <duration>")
          node.retry_max_delay_ms = expect_duration(line.tokens[2], "retry max-delay")
        else
          raise ParseError.new("unknown retry field '#{field}'", line: line.number)
        end
      end

      def parse_queue(header)
        expect_token_count(header, 2, "queue <name>")
        name = expect_identifier(header.tokens[1], "queue name")
        node = AST::Queue.new(name: name, line: header.number)
        advance

        each_body_line("queue #{name}") do |line|
          apply_queue_field(node, line)
        end

        node
      end

      def apply_queue_field(node, line)
        head = line.head.value
        case head
        when "concurrency"
          expect_token_count(line, 2, "concurrency <integer>")
          value = expect_integer(line.tokens[1], "concurrency")
          raise ParseError.new("concurrency must be >= 1", line: line.number) if value < 1
          node.concurrency = value
        when "timeout"
          expect_token_count(line, 2, "timeout <duration>")
          node.timeout_ms = expect_duration(line.tokens[1], "timeout")
        else
          raise ParseError.new("unknown directive '#{head}' in queue", line: line.number)
        end
      end

      def parse_interface(header)
        expect_token_count(header, 3, "interface <type> <name>")
        type = expect_word(header.tokens[1], "interface type")
        plugin = Iface::Registry.lookup(type)
        unless plugin
          allowed = Iface::Registry.types.join(", ")
          raise ParseError.new("invalid interface type '#{type}' (allowed: #{allowed})", line: header.number)
        end
        name = expect_identifier(header.tokens[2], "interface name")
        node = AST::Interface.new(type: type, name: name, line: header.number)
        advance

        each_body_line("interface #{type} #{name}") do |line|
          parse_interface_field(node, line)
        end

        node
      end

      def parse_interface_field(node, line)
        plugin = Iface::Registry.lookup(node.type) or
          raise ParseError.new("interface '#{node.name}' has unknown type '#{node.type}'", line: node.line)
        head = line.head.value

        # Shared shutdown/no-shutdown plumbing — applies to every interface
        # type regardless of plugin, because it's a runtime gate not a
        # type-specific config field.
        case head
        when "shutdown"
          expect_token_count(line, 1, "shutdown")
          node.shutdown = true
          return
        when "no"
          expect_token_count(line, 2, "no shutdown")
          unless line.tokens[1].value == "shutdown"
            raise ParseError.new("only 'no shutdown' is supported here", line: line.number)
          end
          node.shutdown = false
          return
        end

        # Plugin-defined field.
        field = plugin.field_for(head)
        unless field
          raise ParseError.new(
            "unknown directive '#{head}' in interface '#{node.type}'",
            line: line.number
          )
        end

        case field.kind
        when :string
          expect_token_count(line, 2, "#{field.dsl_keyword} <value>")
          node.type_fields[field.storage_key] =
            expect_word_or_string(line.tokens[1], field.dsl_keyword)
        when :path
          expect_token_count(line, 2, "#{field.dsl_keyword} <path>")
          value = expect_word_or_string(line.tokens[1], field.dsl_keyword)
          unless value.start_with?("/")
            raise ParseError.new("#{field.dsl_keyword} must start with '/'", line: line.number)
          end
          node.type_fields[field.storage_key] = value
        when :enum
          expect_token_count(line, 2, "#{field.dsl_keyword} <#{field.enum.join('|')}>")
          value = expect_word(line.tokens[1], field.dsl_keyword)
          unless field.enum.include?(value)
            raise ParseError.new(
              "invalid #{field.dsl_keyword} '#{value}' (allowed: #{field.enum.join(', ')})",
              line: line.number
            )
          end
          node.type_fields[field.storage_key] = value
        when :http_method
          expect_token_count(line, 2, "#{field.dsl_keyword} <METHOD>")
          value = expect_word(line.tokens[1], field.dsl_keyword).upcase
          unless HTTP_METHODS.include?(value)
            raise ParseError.new(
              "invalid HTTP method '#{value}' (allowed: #{HTTP_METHODS.join(', ')})",
              line: line.number
            )
          end
          node.type_fields[field.storage_key] = value
        when :auth_bearer
          expect_token_count(line, 4, "#{field.dsl_keyword} bearer secret <NAME>")
          scheme = expect_word(line.tokens[1], "auth scheme")
          unless AST::Auth::SCHEMES.include?(scheme)
            raise ParseError.new(
              "invalid auth scheme '#{scheme}' (allowed: #{AST::Auth::SCHEMES.join(', ')})",
              line: line.number
            )
          end
          unless line.tokens[2].value == "secret"
            raise ParseError.new("expected 'secret' keyword in #{field.dsl_keyword} directive", line: line.number)
          end
          secret_name = expect_env_name(line.tokens[3], "secret name")
          node.type_fields[field.storage_key] =
            AST::Auth.new(scheme: scheme, secret_name: secret_name, line: line.number)
        when :command
          expect_min_tokens(line, 2, "#{field.dsl_keyword} <args...>")
          node.type_fields[field.storage_key] = line.tokens[1..].map(&:value).join(" ")
        when :env_pair
          expect_token_count(line, 3, "#{field.dsl_keyword} <KEY> <VALUE>")
          key = expect_word(line.tokens[1], "#{field.dsl_keyword} key")
          value = expect_word_or_string(line.tokens[2], "#{field.dsl_keyword} value")
          (node.type_fields[field.storage_key] ||= {})[key] = value
        else
          raise ParseError.new(
            "interface plugin '#{plugin.type_name}' field '#{field.name}' has unknown kind #{field.kind.inspect}",
            line: line.number
          )
        end
      end

      def parse_process(header)
        expect_token_count(header, 2, "process <name>")
        name = expect_identifier(header.tokens[1], "process name")
        node = AST::Process.new(name: name, line: header.number)
        advance

        each_body_line("process #{name}") do |line|
          head = line.head.value
          case head
          when "block"
            node.blocks << parse_block(line)
            next
          when "route"
            node.routes << parse_process_route(line)
            next
          else
            apply_process_field(node, line)
          end
        end

        node
      end

      # Apply a single field-level command (description/queue/shutdown) to a
      # Process node. Sub-section commands (block, route) are NOT handled here
      # — they push a new mode in the shell, or trigger nested parsing in the
      # file parser.
      def apply_process_field(node, line)
        head = line.head.value
        case head
        when "description"
          # router-style: `description` consumes the rest of the line as free
          # text. Quoted strings still work (and stay as a single token);
          # bare words concatenate with single spaces. Renderer re-quotes on
          # output if the result contains whitespace, so roundtrip is safe.
          if line.tokens.length < 2
            raise ParseError.new("description requires text", line: line.number)
          end
          node.description = line.tokens[1..].map(&:value).join(" ")
        when "queue"
          expect_token_count(line, 2, "queue <name>")
          node.queue_name = expect_identifier(line.tokens[1], "queue name")
        when "shutdown"
          expect_token_count(line, 1, "shutdown")
          node.shutdown = true
        when "no"
          expect_token_count(line, 2, "no shutdown")
          unless line.tokens[1].value == "shutdown"
            raise ParseError.new("only 'no shutdown' is supported here", line: line.number)
          end
          node.shutdown = false
        else
          raise ParseError.new("unknown directive '#{head}' in process", line: line.number)
        end
      end

      def parse_block(header)
        expect_token_count(header, 2, "block <name>")
        name = expect_identifier(header.tokens[1], "block name")
        node = AST::Block.new(name: name, line: header.number)
        advance

        each_body_line("block #{name}") do |line|
          parse_block_field(node, line)
        end

        node
      end

      # A block has three kinds of body directives:
      #   1. `interface <type> <name>` — references the outbound interface
      #      this block invokes. Required exactly once. Must come before
      #      any call-fields so the parser can look up the plugin's
      #      call_field schema for the rest of the body.
      #   2. Common fields (`timeout`, `retry`, `secret`, `contract`,
      #      `produces`, `input from`, `enable`/`disable`/`shutdown`/
      #      `no shutdown`) — work the same regardless of which interface.
      #   3. Call-fields — type-specific args validated against the
      #      interface plugin's call_field schema (`method`/`path` for
      #      http, `command` for docker, `prompt` for llm, `exec` for
      #      shell, etc.).
      def parse_block_field(node, line)
        head = line.head.value

        case head
        when "interface"
          parse_block_interface_ref(node, line)
        when "timeout"
          expect_token_count(line, 2, "timeout <duration>")
          node.timeout_ms = expect_duration(line.tokens[1], "timeout")
        when "retry"
          if line.tokens.length == 3 && line.tokens[1].value == "policy"
            node.retry_policy_name = expect_identifier(line.tokens[2], "retry policy name")
          elsif line.tokens.length == 2
            node.retry_policy_name = expect_identifier(line.tokens[1], "retry policy name")
          else
            raise ParseError.new("syntax: retry <policy_name>  or  retry policy <policy_name>", line: line.number)
          end
        when "secret"
          expect_token_count(line, 2, "secret <NAME>")
          secret_name = expect_env_name(line.tokens[1], "secret name")
          if node.secret_names.include?(secret_name)
            raise ParseError.new("duplicate secret '#{secret_name}' in block", line: line.number)
          end
          node.secret_names << secret_name
        when "contract"
          expect_token_count(line, 2, "contract <name>")
          node.contract_name = expect_identifier(line.tokens[1], "contract name")
        when "input"
          # Only the typed-artifact form: `input from <block>.<relpath>`.
          # The legacy `input <context.path>` is gone — templating reads
          # context directly from any call-field via `{{ctx.path}}`.
          unless line.tokens.length == 3 && line.tokens[1].value == "from"
            raise ParseError.new(
              "block 'input' supports only `input from <block>.<relpath>` (typed artifact); " \
              "for context flow, reference paths via {{...}} in call-fields",
              line: line.number
            )
          end
          apply_artifact_input(node, line)
        when "produces"
          expect_token_count(line, 2, "produces <relpath>")
          relpath = expect_artifact_relpath(line.tokens[1], "produces")
          if node.produces.include?(relpath)
            raise ParseError.new("duplicate produces '#{relpath}' in block", line: line.number)
          end
          node.produces << relpath
        when "enable"
          expect_token_count(line, 1, "enable")
          node.shutdown = false
        when "disable"
          expect_token_count(line, 1, "disable")
          node.shutdown = true
        when "shutdown"
          expect_token_count(line, 1, "shutdown")
          node.shutdown = true
        when "no"
          expect_token_count(line, 2, "no shutdown")
          unless line.tokens[1].value == "shutdown"
            raise ParseError.new("only 'no shutdown' is supported here", line: line.number)
          end
          node.shutdown = false
        else
          # Anything else must be a call-field for the interface this block
          # uses. Requires `interface <type> <name>` to have been declared.
          parse_block_call_field(node, line)
        end
      end

      def parse_block_interface_ref(node, line)
        expect_token_count(line, 3, "interface <type> <name>")
        type = expect_word(line.tokens[1], "interface type")
        plugin = Iface::Registry.lookup(type)
        unless plugin
          raise ParseError.new(
            "invalid interface type '#{type}' (registered: #{Iface::Registry.types.join(', ')})",
            line: line.number
          )
        end
        unless plugin.outbound?
          raise ParseError.new(
            "block 'interface' must reference an outbound interface; " \
            "'#{type}' is #{plugin.direction} (only blocks reference outbound)",
            line: line.number
          )
        end
        name = expect_identifier(line.tokens[2], "interface name")
        if node.interface_ref
          raise ParseError.new(
            "block '#{node.name}' already references " \
            "'interface #{node.interface_ref.type} #{node.interface_ref.name}'",
            line: line.number
          )
        end
        node.interface_ref = AST::InterfaceRef.new(type: type, name: name, line: line.number)
      end

      # Apply a per-call argument as defined by the referenced interface's
      # plugin call_field schema. Requires the block's `interface <type>
      # <name>` directive to have been parsed already so we know which
      # plugin's schema is in play.
      def parse_block_call_field(node, line)
        unless node.interface_ref
          raise ParseError.new(
            "unknown directive '#{line.head.value}' in block; " \
            "did you forget `interface <type> <name>` before per-call args?",
            line: line.number
          )
        end

        plugin = Iface::Registry.lookup(node.interface_ref.type)
        # Plugin existence already validated when parsing interface ref.
        head = line.head.value
        field = plugin.call_field_for(head)
        unless field
          allowed = plugin.call_fields.map(&:dsl_keyword).join(", ")
          raise ParseError.new(
            "unknown directive '#{head}' in block (interface '#{node.interface_ref.type} " \
            "#{node.interface_ref.name}' allows: #{allowed.empty? ? '(no call-fields)' : allowed})",
            line: line.number
          )
        end

        apply_call_field_value(plugin, field, node, line)
      end

      def apply_call_field_value(plugin, field, node, line)
        case field.kind
        when :string
          expect_token_count(line, 2, "#{field.dsl_keyword} <value>")
          node.type_fields[field.storage_key] = expect_word_or_string(line.tokens[1], field.dsl_keyword)
        when :enum
          expect_token_count(line, 2, "#{field.dsl_keyword} <#{field.enum.join('|')}>")
          value = expect_word(line.tokens[1], field.dsl_keyword)
          unless field.enum.include?(value)
            raise ParseError.new(
              "invalid #{field.dsl_keyword} '#{value}' (allowed: #{field.enum.join(', ')})",
              line: line.number
            )
          end
          node.type_fields[field.storage_key] = value
        when :http_method
          expect_token_count(line, 2, "#{field.dsl_keyword} <METHOD>")
          value = expect_word(line.tokens[1], field.dsl_keyword).upcase
          unless HTTP_METHODS.include?(value)
            raise ParseError.new(
              "invalid HTTP method '#{value}' (allowed: #{HTTP_METHODS.join(', ')})",
              line: line.number
            )
          end
          node.type_fields[field.storage_key] = value
        when :command
          expect_min_tokens(line, 2, "#{field.dsl_keyword} <args...>")
          node.type_fields[field.storage_key] = line.tokens[1..].map(&:value).join(" ")
        when :env_pair
          expect_token_count(line, 3, "#{field.dsl_keyword} <KEY> <VALUE>")
          key = expect_word(line.tokens[1], "#{field.dsl_keyword} key")
          value = expect_word_or_string(line.tokens[2], "#{field.dsl_keyword} value")
          (node.type_fields[field.storage_key] ||= {})[key] = value
        else
          raise ParseError.new(
            "interface plugin '#{plugin.type_name}' call_field '#{field.name}' has unknown kind #{field.kind.inspect}",
            line: line.number
          )
        end
      end

      # `input from <block>.<relpath>` — declare that this block consumes a
      # named artifact produced by an upstream block. The artifact reference
      # is split on the FIRST dot: block names are dotless identifiers,
      # artifact paths may contain dots and slashes (e.g. `subdir/file.json`).
      # The local name (used for /prouter/inputs/<local> and PROUTER_INPUT_<UPPER>)
      # is derived from the basename minus its last extension.
      # Collision detection lives in the validator: a clear error there
      # tells operators to rename `produces` upstream.
      def apply_artifact_input(node, line)
        ref = expect_word(line.tokens[2], "from <block>.<relpath>")
        dot = ref.index(".")
        unless dot && dot.positive? && dot < ref.length - 1
          raise ParseError.new("expected 'from <block>.<relpath>', got '#{ref}'", line: line.number)
        end

        from_block = ref[0...dot]
        from_artifact = ref[(dot + 1)..]
        unless from_block.match?(IDENT_RE)
          raise ParseError.new("invalid block name '#{from_block}' in artifact reference", line: line.number)
        end
        if from_artifact.empty? || from_artifact.start_with?("/") || from_artifact.split("/").include?("..")
          raise ParseError.new("invalid artifact path '#{from_artifact}' (must be a relative path)", line: line.number)
        end

        # Make sure the basename produces a usable identifier (env-var suffix);
        # otherwise we'd silently emit something like `PROUTER_INPUT_FILE-01`.
        # Stricter than IDENT_RE: no hyphens — env-var rules.
        derived = File.basename(from_artifact, ".*")
        unless derived.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ParseError.new(
            "cannot derive a local name from '#{from_artifact}'; rename the file upstream so its basename is alphanumeric/underscore",
            line: line.number
          )
        end

        node.artifact_inputs << AST::ArtifactInput.new(
          from_block: from_block,
          from_artifact: from_artifact,
          line: line.number
        )
      end

      def parse_process_route(header)
        expect_token_count(header, 3, "route <from_block> <to_block>")
        from = expect_identifier(header.tokens[1], "from-block name")
        to = expect_identifier(header.tokens[2], "to-block name")
        route = AST::ProcessRoute.new(from_block: from, to_block: to, line: header.number)
        advance

        # Look ahead: long form requires a body keyword on the next line.
        next_line = current_line
        return route unless next_line && route_body_keyword?(next_line)

        each_body_line("route #{from} #{to}") do |line|
          parse_process_route_field(route, line)
        end

        route
      end

      def route_body_keyword?(line)
        head = line.head.value
        return true if %w[match on-failure shutdown].include?(head)

        head == "no" && line.tokens[1] && line.tokens[1].value == "shutdown"
      end

      def parse_process_route_field(route, line)
        head = line.head.value
        case head
        when "match"
          route.matches << parse_match(line)
        when "on-failure"
          expect_token_count(line, 2, "on-failure <stop|continue>")
          value = expect_word(line.tokens[1], "on-failure")
          unless AST::ProcessRoute::ON_FAILURE_VALUES.include?(value)
            raise ParseError.new("invalid on-failure '#{value}' (allowed: stop, continue)", line: line.number)
          end
          route.on_failure = value
        when "shutdown"
          expect_token_count(line, 1, "shutdown")
          route.shutdown = true
        when "no"
          expect_token_count(line, 2, "no shutdown")
          unless line.tokens[1].value == "shutdown"
            raise ParseError.new("only 'no shutdown' is supported here", line: line.number)
          end
          route.shutdown = false
        else
          raise ParseError.new("unknown directive '#{head}' in route body", line: line.number)
        end
      end

      def parse_global_route(header)
        expect_min_tokens(header, 5, "route interface <iface_name> process <process_name>")
        unless header.tokens[1].value == "interface" && header.tokens[3].value == "process"
          raise ParseError.new("expected 'route interface <name> process <name>'", line: header.number)
        end
        expect_token_count(header, 5, "route interface <iface_name> process <process_name>")

        iface_name = expect_identifier(header.tokens[2], "interface name")
        proc_name = expect_identifier(header.tokens[4], "process name")
        route = AST::GlobalRoute.new(interface_name: iface_name, process_name: proc_name, line: header.number)
        advance

        each_body_line("route interface #{iface_name} process #{proc_name}") do |line|
          apply_global_route_field(route, line)
        end

        route
      end

      def apply_global_route_field(route, line)
        head = line.head.value
        case head
        when "match"
          route.matches << parse_match(line)
        else
          raise ParseError.new("unknown directive '#{head}' in global route", line: line.number)
        end
      end

      # ----- contracts (Phase 14) -----

      # `contract <name>` — top-level section that declares constraints over
      # a block's output JSON. Multiple `require <path>` lines for the same
      # path accumulate into one Requirement; `optional <path>` makes the
      # path's presence non-mandatory but still applies any constraints.
      def parse_contract(header)
        expect_token_count(header, 2, "contract <name>")
        name = expect_identifier(header.tokens[1], "contract name")
        node = AST::Contract.new(name: name, line: header.number)
        advance

        each_body_line("contract #{name}") do |line|
          apply_contract_field(node, line)
        end

        node
      end

      def apply_contract_field(node, line)
        head = line.head.value
        case head
        when "require"  then parse_constraint_line(node, line, required: true)
        when "optional" then parse_constraint_line(node, line, required: false)
        when "on"
          # `on violation <retry|fail|warn>`
          unless line.tokens.length == 3 && line.tokens[1].value == "violation"
            raise ParseError.new("syntax: on violation <retry|fail|warn>", line: line.number)
          end
          value = expect_word(line.tokens[2], "on violation")
          unless AST::Contract::ON_VIOLATION_VALUES.include?(value)
            raise ParseError.new(
              "invalid on-violation '#{value}' (allowed: #{AST::Contract::ON_VIOLATION_VALUES.join(', ')})",
              line: line.number
            )
          end
          node.on_violation = value
        else
          raise ParseError.new("unknown directive '#{head}' in contract", line: line.number)
        end
      end

      # `require <path> [type T] [min N] [max N] [length N] [min-length N]
      #   [max-length N] [format F] [pattern "..."] [in v1,v2,...]`
      #
      # Same grammar for `optional`. Constraints are attribute key + value
      # pairs after the path, parsed greedily until end of line.
      def parse_constraint_line(node, line, required:)
        expect_min_tokens(line, 2, "require/optional <path> [constraints...]")
        path = expect_context_path(line.tokens[1], "constraint path")

        req = node.upsert_requirement(path: path, required: required, line: line.number)
        apply_constraint_attributes(req, line, line.tokens[2..])
      end

      def apply_constraint_attributes(req, line, tokens)
        i = 0
        while i < tokens.length
          key = expect_word(tokens[i], "constraint attribute")
          case key
          when "type"
            value = require_token!(line, tokens, i + 1, "type <integer|number|string|boolean|array|object>")
            unless AST::Requirement::TYPES.include?(value)
              raise ParseError.new(
                "invalid type '#{value}' (allowed: #{AST::Requirement::TYPES.join(', ')})",
                line: line.number
              )
            end
            req.type = value
            i += 2
          when "min"
            req.min = parse_constraint_number(line, tokens, i + 1, "min")
            i += 2
          when "max"
            req.max = parse_constraint_number(line, tokens, i + 1, "max")
            i += 2
          when "length"
            req.length = parse_constraint_int(line, tokens, i + 1, "length")
            i += 2
          when "min-length"
            req.min_length = parse_constraint_int(line, tokens, i + 1, "min-length")
            i += 2
          when "max-length"
            req.max_length = parse_constraint_int(line, tokens, i + 1, "max-length")
            i += 2
          when "format"
            value = require_token!(line, tokens, i + 1, "format <#{AST::Requirement::FORMATS.join('|')}>")
            unless AST::Requirement::FORMATS.include?(value)
              raise ParseError.new(
                "invalid format '#{value}' (allowed: #{AST::Requirement::FORMATS.join(', ')})",
                line: line.number
              )
            end
            req.format = value
            i += 2
          when "pattern"
            req.pattern = require_token!(line, tokens, i + 1, "pattern <regex>")
            i += 2
          when "in"
            raw = tokens[(i + 1)..].map(&:value).join(" ")
            values = split_csv_values(raw, line)
            raise ParseError.new("'in' requires at least one value", line: line.number) if values.empty?

            req.enum = values
            i = tokens.length # consumes rest
          else
            raise ParseError.new("unknown constraint attribute '#{key}'", line: line.number)
          end
        end
      end

      def require_token!(line, tokens, index, syntax)
        unless tokens[index]
          raise ParseError.new("expected value: #{syntax}", line: line.number)
        end
        tokens[index].value
      end

      def parse_constraint_number(line, tokens, index, label)
        v = require_token!(line, tokens, index, "#{label} <number>")
        if v.match?(/\A-?\d+\z/)
          v.to_i
        elsif v.match?(/\A-?\d+\.\d+\z/)
          v.to_f
        else
          raise ParseError.new("expected number for #{label}, got '#{v}'", line: line.number)
        end
      end

      def parse_constraint_int(line, tokens, index, label)
        v = require_token!(line, tokens, index, "#{label} <integer>")
        unless v.match?(/\A\d+\z/)
          raise ParseError.new("expected non-negative integer for #{label}, got '#{v}'", line: line.number)
        end
        v.to_i
      end

      # ----- match expressions -----

      def parse_match(line)
        expect_min_tokens(line, 3, "match <path> <op> [value...]")
        path = expect_context_path(line.tokens[1], "match path")
        operator = expect_word(line.tokens[2], "match operator")
        unless AST::Match::OPERATORS.include?(operator)
          raise ParseError.new("invalid match operator '#{operator}' (allowed: #{AST::Match::OPERATORS.join(', ')})", line: line.number)
        end

        if AST::Match::UNARY_OPERATORS.include?(operator)
          expect_token_count(line, 3, "match <path> #{operator}")
          values = []
        elsif AST::Match::MULTI_VALUE_OPERATORS.include?(operator)
          expect_min_tokens(line, 4, "match <path> #{operator} <value1>,<value2>,...")
          raw = line.tokens[3..].map(&:value).join(" ")
          values = split_csv_values(raw, line)
          raise ParseError.new("'in' operator requires at least one value", line: line.number) if values.empty?
        else
          expect_token_count(line, 4, "match <path> #{operator} <value>")
          values = [scalar_value(line.tokens[3])]
        end

        AST::Match.new(path: path, operator: operator, values: values, line: line.number)
      end

      # Splits a comma-separated value list, respecting quoted strings via prior
      # tokenization (the lexer already handled quotes, so this works on the
      # joined raw form `"US","EU"` or `"US"   ,   "EU"`).
      def split_csv_values(raw, line)
        values = []
        i = 0
        len = raw.length
        while i < len
          # skip whitespace and leading comma separators
          i += 1 while i < len && (raw[i] == " " || raw[i] == "\t" || raw[i] == ",")
          break if i >= len

          if raw[i] == '"'
            j = i + 1
            buf = String.new
            while j < len && raw[j] != '"'
              if raw[j] == "\\" && j + 1 < len
                buf << raw[j + 1]
                j += 2
              else
                buf << raw[j]
                j += 1
              end
            end
            raise ParseError.new("unterminated string in match value list", line: line.number) if j >= len
            values << buf
            i = j + 1
          else
            j = i
            j += 1 while j < len && raw[j] != "," && raw[j] != " " && raw[j] != "\t"
            values << coerce_scalar(raw[i...j])
            i = j
          end
        end
        values
      end

      def scalar_value(token)
        token.string? ? token.value : coerce_scalar(token.value)
      end

      def coerce_scalar(text)
        return text.to_i if text.match?(/\A-?\d+\z/)
        return text.to_f if text.match?(/\A-?\d+\.\d+\z/)
        return true if text == "true"
        return false if text == "false"

        text
      end

      # ----- traversal helpers -----

      def current_line
        @lines[@pos]
      end

      def peek
        @lines[@pos]
      end

      def advance
        @pos += 1
      end

      # Iterates over a section body until an `exit` line, advancing past it.
      def each_body_line(context)
        loop do
          line = current_line
          if line.nil?
            raise ParseError.new("unexpected end of input in #{context} (missing 'exit')", line: nil)
          end
          if line.head.value == "exit"
            expect_token_count(line, 1, "exit")
            advance
            return
          end

          previous_pos = @pos
          yield line

          # If the block didn't advance, we advance one line. Sub-section parsers
          # (block, route, process) advance themselves and call `next`.
          advance if @pos == previous_pos
        end
      end

      # ----- token expectation helpers -----

      def expect_token_count(line, count, syntax)
        return if line.tokens.length == count

        raise ParseError.new("expected '#{syntax}', got #{line.tokens.length} token(s)", line: line.number)
      end

      def expect_min_tokens(line, count, syntax)
        return if line.tokens.length >= count

        raise ParseError.new("expected '#{syntax}', got #{line.tokens.length} token(s)", line: line.number)
      end

      def expect_word(token, label)
        unless token.word?
          raise ParseError.new("expected #{label} as bare word, got string", line: token.line, column: token.column)
        end
        token.value
      end

      def expect_word_or_string(token, _label)
        token.value
      end

      def expect_identifier(token, label)
        value = expect_word(token, label)
        unless value.match?(IDENT_RE)
          raise ParseError.new("invalid #{label} '#{value}' (must match #{IDENT_RE.source})", line: token.line, column: token.column)
        end
        value
      end

      def expect_env_name(token, label)
        value = expect_word(token, label)
        unless value.match?(ENV_NAME_RE)
          raise ParseError.new("invalid #{label} '#{value}' (must be uppercase A-Z, 0-9, _)", line: token.line, column: token.column)
        end
        value
      end

      def expect_integer(token, label)
        value = expect_word(token, label)
        unless value.match?(/\A-?\d+\z/)
          raise ParseError.new("expected integer for #{label}, got '#{value}'", line: token.line, column: token.column)
        end
        value.to_i
      end

      def expect_duration(token, label)
        value = expect_word(token, label)
        Util::DurationParser.parse(value)
      rescue ArgumentError => e
        raise ParseError.new("invalid #{label}: #{e.message}", line: token.line, column: token.column)
      end

      def expect_context_path(token, label)
        value = expect_word(token, label)
        unless value.match?(/\A[A-Za-z_][A-Za-z0-9_.]*\z/)
          raise ParseError.new("invalid #{label} path '#{value}' (must be dotted identifier)", line: token.line, column: token.column)
        end
        value
      end

      # Relative path inside /prouter/artifacts/. Slashes allowed for
      # subdirectories; no leading slash, no `..`, no whitespace.
      def expect_artifact_relpath(token, label)
        value = expect_word(token, label)
        if value.empty? || value.start_with?("/") || value.split("/").include?("..")
          raise ParseError.new("invalid #{label} path '#{value}' (must be a relative path under artifacts/)", line: token.line, column: token.column)
        end
        value
      end

      # Field-application methods are reused by the interactive shell so that
      # validation of `version 1`, `image foo:bar`, etc. lives in exactly one
      # place. Re-exposed publicly here at the end of the class.
      public :apply_router_field,
             :apply_secret_field,
             :apply_policy_field,
             :apply_queue_field,
             :apply_process_field,
             :apply_global_route_field,
             :parse_interface_field,
             :parse_block_field,
             :parse_process_route_field
    end
  end
end
