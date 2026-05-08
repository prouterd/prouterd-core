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

      def self.parse(lines, base_dir: nil)
        new(lines, base_dir: base_dir).parse
      end

      # `base_dir` is the directory used to resolve relative paths in
      # `<call-field> file <path>` directives (e.g. `prompt file "x.md"`).
      # Callers that parse a stored config string (DB, shell builder)
      # leave it nil; the file form then errors with a clear message.
      def initialize(lines, base_dir: nil)
        @lines = lines
        @pos = 0
        @base_dir = base_dir
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
          when "tool"      then doc.tools << parse_tool(line)
          when "prices"    then doc.prices << parse_prices(line)
          when "mcp_tool"  then parse_mcp_tool(doc, line)
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
        when "when"
          # `retry when <path> <op> <value>` — gates retries on the failure
          # result. Reuses the route-match parser by skipping the leading
          # `retry` token and treating `when` as if it were `match`.
          node.retry_when_matches << parse_match_at(line, 1)
        when "stop-on"
          # `retry stop-on <path> <op> <value>` — kill switch evaluated
          # against current run state (run.cost_usd, etc.) after every
          # attempt. Reuses the route-match parser by pretending the
          # leading `retry` token is the section keyword.
          node.retry_stop_matches << parse_match_at(line, 1)
        when "feedback"
          # `retry feedback <output-path> into <local>` — copy a path out
          # of the failed attempt's output_json into the next attempt's
          # `previous.<local>` overlay. Used by reflection loops.
          unless line.tokens.length == 5 && line.tokens[3].value == "into"
            raise ParseError.new(
              "syntax: retry feedback <output-path> into <local-name>",
              line: line.number
            )
          end
          from = expect_word_or_string(line.tokens[2], "retry feedback path")
          into = expect_identifier(line.tokens[4], "retry feedback target name")
          node.retry_feedbacks << AST::Policy::Feedback.new(from: from, into: into, line: line.number)
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
          when "parallel"
            parse_parallel_group(node, line)
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
        when "timeout"
          expect_token_count(line, 2, "timeout <duration>")
          node.timeout_ms = expect_duration(line.tokens[1], "timeout")
        when "thread-id"
          expect_token_count(line, 2, "thread-id <template>")
          node.thread_id_template = expect_word_or_string(line.tokens[1], "thread-id template")
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

      # `parallel <name> ... block X ... block Y ... [join-strategy ...] exit`
      # Side effects on the parent process node:
      #   - each child block is appended to process.blocks
      #   - a synthesized barrier block named <name> is appended; it has
      #     no interface, and is scheduled by the orchestrator as a
      #     no-op aggregator over the children's outputs
      #   - synthesized routes from each child to the barrier are added
      #     to process.routes (with on-failure tied to the join strategy)
      #   - the source-form record is kept on process.parallel_groups
      #     for rendering
      def parse_parallel_group(process_node, header)
        expect_token_count(header, 2, "parallel <name>")
        name = expect_identifier(header.tokens[1], "parallel group name")
        if process_node.blocks.any? { |b| b.name == name } ||
           process_node.parallel_groups.any? { |g| g.name == name }
          raise ParseError.new("name '#{name}' is already declared in process '#{process_node.name}'", line: header.number)
        end

        group = AST::ParallelGroup.new(name: name, line: header.number)
        advance

        each_body_line("parallel #{name}") do |line|
          head = line.head.value
          case head
          when "block"
            child = parse_block(line)
            if process_node.blocks.any? { |b| b.name == child.name }
              raise ParseError.new("duplicate block '#{child.name}' inside parallel '#{name}'", line: child.line)
            end
            process_node.blocks << child
            group.member_block_names << child.name
          when "join-strategy"
            expect_token_count(line, 2, "join-strategy <#{AST::ParallelGroup::JOIN_STRATEGIES.join('|')}>")
            value = expect_word(line.tokens[1], "join-strategy")
            unless AST::ParallelGroup::JOIN_STRATEGIES.include?(value)
              raise ParseError.new(
                "invalid join-strategy '#{value}' (allowed: #{AST::ParallelGroup::JOIN_STRATEGIES.join(', ')})",
                line: line.number
              )
            end
            group.join_strategy = value
          else
            raise ParseError.new("unknown directive '#{head}' inside parallel '#{name}'", line: line.number)
          end
        end

        if group.member_block_names.empty?
          raise ParseError.new("parallel '#{name}' must contain at least one block", line: header.number)
        end

        # Synthesize the barrier block.
        barrier = AST::Block.new(name: name, line: header.number)
        barrier.barrier_for = group.member_block_names.dup
        barrier.barrier_join_strategy = group.join_strategy
        process_node.blocks << barrier

        # Synthesize routes child -> barrier. all-best-effort needs
        # on-failure=continue so a failed child doesn't abort the run
        # before the barrier can pick up the survivors.
        on_failure = group.join_strategy == "all-best-effort" ? "continue" : "stop"
        group.member_block_names.each do |child_name|
          route = AST::ProcessRoute.new(from_block: child_name, to_block: name, line: header.number)
          route.on_failure = on_failure
          process_node.routes << route
        end

        process_node.parallel_groups << group
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
        when "skip-when"
          if node.skip_when
            raise ParseError.new("block '#{node.name}' already has a skip-when", line: line.number)
          end
          node.skip_when = parse_match_at(line, 0)
        when "vars"
          parse_block_vars(node, line)
        when "agentic"
          expect_token_count(line, 2, "agentic <on|off>")
          value = expect_word(line.tokens[1], "agentic")
          unless %w[on off].include?(value)
            raise ParseError.new("invalid agentic value '#{value}' (allowed: on, off)", line: line.number)
          end
          node.agentic = (value == "on")
        when "allowed-tools"
          expect_min_tokens(line, 2, "allowed-tools <name>[, <name>...]")
          raw = line.tokens[1..].map(&:value).join(" ")
          names = raw.split(",").map(&:strip).reject(&:empty?)
          names.each do |t|
            unless t.match?(IDENT_RE)
              raise ParseError.new("invalid tool name '#{t}' in allowed-tools", line: line.number)
            end
          end
          node.allowed_tools.replace((node.allowed_tools + names).uniq)
        when "tool-call-limit"
          expect_token_count(line, 2, "tool-call-limit <integer>")
          value = expect_integer(line.tokens[1], "tool-call-limit")
          raise ParseError.new("tool-call-limit must be >= 1", line: line.number) if value < 1
          node.tool_call_limit = value
        when "max-cost-usd"
          expect_token_count(line, 2, "max-cost-usd <decimal>")
          value = expect_decimal(line.tokens[1], "max-cost-usd")
          raise ParseError.new("max-cost-usd must be > 0", line: line.number) unless value.positive?
          node.max_cost_usd = value
        when "fan-out"
          # `fan-out from <path> into <process>` — after this block
          # succeeds, walk the named array path in output_json and
          # enqueue one run of <process> per element.
          unless line.tokens.length == 5 &&
                 line.tokens[1].value == "from" &&
                 line.tokens[3].value == "into"
            raise ParseError.new(
              "syntax: fan-out from <output-path> into <process-name>",
              line: line.number
            )
          end
          if node.fan_out_from
            raise ParseError.new("block '#{node.name}' already has a fan-out", line: line.number)
          end
          node.fan_out_from = expect_word_or_string(line.tokens[2], "fan-out path")
          node.fan_out_into = expect_identifier(line.tokens[4], "fan-out target process")
        when "pause"
          if node.interface_ref
            raise ParseError.new(
              "block '#{node.name}': `pause` blocks have no interface dispatch — " \
              "remove the `interface ...` directive",
              line: line.number
            )
          end
          if node.pause_reason
            raise ParseError.new("block '#{node.name}' already has a `pause` directive", line: line.number)
          end
          expect_token_count(line, 2, "pause <reason>")
          node.pause_reason = expect_word_or_string(line.tokens[1], "pause reason")
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
        if node.pause_reason
          raise ParseError.new(
            "block '#{node.name}': cannot mix `pause` and `interface` — " \
            "pause blocks have no interface dispatch",
            line: line.number
          )
        end
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
        if call_field_file_form?(field, line)
          apply_call_field_from_file(field, node, line)
          return
        end

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

      # `vars` sub-section — local-name overlay for templating call-fields.
      # Each line is `<name> <value>` where <value> is itself a template
      # resolved against the regular context at run time.
      def parse_block_vars(node, header)
        expect_token_count(header, 1, "vars")
        advance
        each_body_line("vars in block #{node.name}") do |line|
          expect_token_count(line, 2, "<name> <value>")
          name = expect_identifier(line.tokens[0], "var name")
          if node.vars.key?(name)
            raise ParseError.new("duplicate var '#{name}' in block '#{node.name}'", line: line.number)
          end
          node.vars[name] = expect_word_or_string(line.tokens[1], "var value")
        end
      end

      # `<call-field> file <path>` — for text-typed call-fields (`:command`
      # or `:string`), inline the contents of an external file at parse
      # time. Path resolves relative to the .prc file's directory.
      def call_field_file_form?(field, line)
        return false unless %i[command string].include?(field.kind)
        return false unless line.tokens.length >= 2
        line.tokens[1].value == "file"
      end

      def apply_call_field_from_file(field, node, line)
        unless line.tokens.length == 3
          raise ParseError.new(
            "syntax: #{field.dsl_keyword} file <path>",
            line: line.number
          )
        end
        unless @base_dir
          raise ParseError.new(
            "#{field.dsl_keyword} file <path> requires a base directory; " \
            "load this config via a file path (e.g. `prouter apply <file>`) " \
            "rather than from a string",
            line: line.number
          )
        end
        path = expect_word_or_string(line.tokens[2], "#{field.dsl_keyword} file <path>")
        expanded = File.expand_path(path, @base_dir)
        begin
          content = File.read(expanded)
        rescue Errno::ENOENT
          raise ParseError.new(
            "cannot read #{field.dsl_keyword} file '#{path}': not found at #{expanded}",
            line: line.number
          )
        rescue SystemCallError => e
          raise ParseError.new(
            "cannot read #{field.dsl_keyword} file '#{path}': #{e.message}",
            line: line.number
          )
        end
        node.type_fields[field.storage_key] = content
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
      # `tool <name> ... exit` — top-level tool declaration. Body:
      #   description "<text>"
      #   args a, b, c
      #   implementation interface <type> <iface> call <call_name>
      def parse_tool(header)
        expect_token_count(header, 2, "tool <name>")
        name = expect_identifier(header.tokens[1], "tool name")
        node = AST::Tool.new(name: name, line: header.number)
        advance

        each_body_line("tool #{name}") do |line|
          head = line.head.value
          case head
          when "description"
            if line.tokens.length < 2
              raise ParseError.new("description requires text", line: line.number)
            end
            node.description = line.tokens[1..].map(&:value).join(" ")
          when "args"
            expect_min_tokens(line, 2, "args <name>[, <name>...]")
            raw = line.tokens[1..].map(&:value).join(" ")
            args = raw.split(",").map(&:strip).reject(&:empty?)
            args.each do |a|
              unless a.match?(IDENT_RE)
                raise ParseError.new("invalid arg name '#{a}'", line: line.number)
              end
            end
            if args.uniq.length != args.length
              raise ParseError.new("duplicate arg name(s) in tool '#{name}'", line: line.number)
            end
            node.args.replace(args)
          when "implementation"
            unless line.tokens.length == 6 &&
                   line.tokens[1].value == "interface" &&
                   line.tokens[4].value == "call"
              raise ParseError.new(
                "syntax: implementation interface <type> <iface_name> call <call_name>",
                line: line.number
              )
            end
            iface_type = expect_word(line.tokens[2], "implementation interface type")
            iface_name = expect_identifier(line.tokens[3], "implementation interface name")
            call_name  = expect_identifier(line.tokens[5], "implementation call name")
            node.implementation = AST::Tool::Implementation.new(
              iface_type: iface_type,
              iface_name: iface_name,
              call_name:  call_name
            )
          else
            raise ParseError.new("unknown directive '#{head}' in tool", line: line.number)
          end
        end

        node
      end

      # `mcp_tool <name> ... exit` — pure parser sugar for the common
      # case where an integration is one shell-script with an `op`
      # discriminator and JSON I/O. Expands at parse time into:
      #
      #   interface shell <name>     ! one per mcp_tool
      #    cwd <body.cwd>            ! optional
      #   exit
      #
      #   tool <name>
      #    description "<body.description>"
      #    args <body.args>
      #    implementation interface shell <name> call exec
      #   exit
      #
      # Body keys: description, args, exec, cwd. `exec` becomes the
      # interface's call_field default at runtime — but since we model
      # tools as call_name="exec" against the shell iface, the actual
      # exec line is supplied by the LLM-generated args at dispatch
      # time. Carrying `exec` here is for completeness when the operator
      # wants a fixed prefix.
      def parse_mcp_tool(doc, header)
        expect_token_count(header, 2, "mcp_tool <name>")
        name = expect_identifier(header.tokens[1], "mcp_tool name")
        if doc.interfaces.any? { |i| i.name == name } || doc.tools.any? { |t| t.name == name }
          raise ParseError.new("name '#{name}' is already declared", line: header.number)
        end
        advance

        body = { description: nil, args: [], exec: nil, cwd: nil }
        each_body_line("mcp_tool #{name}") do |line|
          head = line.head.value
          case head
          when "description"
            if line.tokens.length < 2
              raise ParseError.new("description requires text", line: line.number)
            end
            body[:description] = line.tokens[1..].map(&:value).join(" ")
          when "args"
            expect_min_tokens(line, 2, "args <name>[, <name>...]")
            raw = line.tokens[1..].map(&:value).join(" ")
            args = raw.split(",").map(&:strip).reject(&:empty?)
            args.each do |a|
              unless a.match?(IDENT_RE)
                raise ParseError.new("invalid arg name '#{a}'", line: line.number)
              end
            end
            body[:args] = args
          when "exec"
            expect_min_tokens(line, 2, "exec <command>")
            body[:exec] = line.tokens[1..].map(&:value).join(" ")
          when "cwd"
            expect_token_count(line, 2, "cwd <path>")
            body[:cwd] = expect_word_or_string(line.tokens[1], "cwd")
          else
            raise ParseError.new("unknown directive '#{head}' in mcp_tool", line: line.number)
          end
        end

        # Synthesize: interface shell <name> + tool <name>.
        iface = AST::Interface.new(type: "shell", name: name, line: header.number)
        iface.type_fields["cwd"] = body[:cwd] if body[:cwd]
        doc.interfaces << iface

        tool = AST::Tool.new(name: name, line: header.number)
        tool.description = body[:description]
        tool.args.replace(body[:args])
        tool.implementation = AST::Tool::Implementation.new(
          iface_type: "shell", iface_name: name, call_name: "exec"
        )
        doc.tools << tool
      end

      # `prices <provider> ... exit` — body lines look like
      #   model <name>  in <usd>  out <usd>
      # Rates are per-million-token. Stored on doc.prices for the
      # runtime cost accumulator.
      def parse_prices(header)
        expect_token_count(header, 2, "prices <provider>")
        provider = expect_word(header.tokens[1], "prices provider")
        node = AST::Prices.new(provider: provider, line: header.number)
        advance

        each_body_line("prices #{provider}") do |line|
          unless line.head.value == "model"
            raise ParseError.new("unknown directive '#{line.head.value}' in prices (expected 'model')", line: line.number)
          end
          unless line.tokens.length == 6 &&
                 line.tokens[2].value == "in" &&
                 line.tokens[4].value == "out"
            raise ParseError.new(
              "syntax: model <name> in <usd-per-1M-input> out <usd-per-1M-output>",
              line: line.number
            )
          end
          model_name = expect_word_or_string(line.tokens[1], "model name")
          price_in   = expect_decimal(line.tokens[3], "in price")
          price_out  = expect_decimal(line.tokens[5], "out price")
          if node.entries.any? { |e| e.model == model_name }
            raise ParseError.new("duplicate model '#{model_name}' in prices '#{provider}'", line: line.number)
          end
          node.entries << AST::Prices::Entry.new(
            model: model_name, price_in: price_in, price_out: price_out, line: line.number
          )
        end

        node
      end

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
        parse_match_at(line, 0)
      end

      # Parse a match expression starting at `head_offset` tokens past the
      # leading keyword. `match <path> <op> <val>` uses head_offset = 0;
      # `retry when <path> <op> <val>` uses head_offset = 1 (skipping the
      # `retry` head so `when` lands at tokens[head_offset]).
      def parse_match_at(line, head_offset)
        path_idx = head_offset + 1
        op_idx   = head_offset + 2
        val_idx  = head_offset + 3

        expect_min_tokens(line, val_idx, "match <path> <op> [value...]")
        path = expect_context_path(line.tokens[path_idx], "match path")
        operator = expect_word(line.tokens[op_idx], "match operator")
        unless AST::Match::OPERATORS.include?(operator)
          raise ParseError.new("invalid match operator '#{operator}' (allowed: #{AST::Match::OPERATORS.join(', ')})", line: line.number)
        end

        if AST::Match::UNARY_OPERATORS.include?(operator)
          expect_token_count(line, val_idx, "match <path> #{operator}")
          values = []
        elsif AST::Match::MULTI_VALUE_OPERATORS.include?(operator)
          expect_min_tokens(line, val_idx + 1, "match <path> #{operator} <value1>,<value2>,...")
          raw = line.tokens[val_idx..].map(&:value).join(" ")
          values = split_csv_values(raw, line)
          raise ParseError.new("'in' operator requires at least one value", line: line.number) if values.empty?
        else
          expect_token_count(line, val_idx + 1, "match <path> #{operator} <value>")
          values = [scalar_value(line.tokens[val_idx])]
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

      def expect_decimal(token, label)
        value = expect_word(token, label)
        unless value.match?(/\A-?\d+(?:\.\d+)?\z/)
          raise ParseError.new("expected decimal for #{label}, got '#{value}'", line: token.line, column: token.column)
        end
        value.to_f
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
