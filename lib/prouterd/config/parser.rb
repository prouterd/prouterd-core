require_relative "../util/duration_parser"

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
      HTTP_METHODS = %w[GET POST PUT PATCH DELETE].freeze
      BACKOFF_TYPES = AST::Policy::BACKOFF_TYPES
      INTERFACE_TYPES = AST::Interface::TYPES

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

      def apply_secret_field(node, line)
        head = line.head.value
        case head
        when "source"
          expect_min_tokens(line, 3, "source env <NAME>")
          kind = line.tokens[1].value
          raise ParseError.new("unsupported secret source '#{kind}', only 'env' is supported", line: line.number) unless kind == "env"
          expect_token_count(line, 3, "source env <NAME>")
          node.source_type = "env"
          node.source_value = expect_env_name(line.tokens[2], "env variable")
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
        unless INTERFACE_TYPES.include?(type)
          raise ParseError.new("invalid interface type '#{type}' (allowed: #{INTERFACE_TYPES.join(', ')})", line: header.number)
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
        head = line.head.value

        case head
        when "shutdown"
          expect_token_count(line, 1, "shutdown")
          node.shutdown = true
        when "no"
          expect_token_count(line, 2, "no shutdown")
          unless line.tokens[1].value == "shutdown"
            raise ParseError.new("only 'no shutdown' is supported here", line: line.number)
          end
          node.shutdown = false
        when "path"
          require_interface_type(node, "webhook", "path", line)
          expect_token_count(line, 2, "path <path>")
          path = expect_word_or_string(line.tokens[1], "path")
          raise ParseError.new("path must start with '/'", line: line.number) unless path.start_with?("/")
          node.path = path
        when "method"
          require_interface_type(node, "webhook", "method", line)
          expect_token_count(line, 2, "method <METHOD>")
          method = expect_word(line.tokens[1], "method").upcase
          unless HTTP_METHODS.include?(method)
            raise ParseError.new("invalid HTTP method '#{method}' (allowed: #{HTTP_METHODS.join(', ')})", line: line.number)
          end
          node.method = method
        when "auth"
          require_interface_type(node, "webhook", "auth", line)
          expect_token_count(line, 4, "auth bearer secret <NAME>")
          scheme = expect_word(line.tokens[1], "auth scheme")
          unless AST::Auth::SCHEMES.include?(scheme)
            raise ParseError.new("invalid auth scheme '#{scheme}' (allowed: #{AST::Auth::SCHEMES.join(', ')})", line: line.number)
          end
          unless line.tokens[2].value == "secret"
            raise ParseError.new("expected 'secret' keyword in auth directive", line: line.number)
          end
          secret_name = expect_env_name(line.tokens[3], "secret name")
          node.auth = AST::Auth.new(scheme: scheme, secret_name: secret_name, line: line.number)
        when "schedule"
          require_interface_type(node, "cron", "schedule", line)
          expect_token_count(line, 2, "schedule <cron-expression>")
          node.schedule = expect_word_or_string(line.tokens[1], "schedule")
        when "timezone"
          require_interface_type(node, "cron", "timezone", line)
          expect_token_count(line, 2, "timezone <tz>")
          node.timezone = expect_word_or_string(line.tokens[1], "timezone")
        else
          raise ParseError.new("unknown directive '#{head}' in interface #{node.type}", line: line.number)
        end
      end

      def require_interface_type(node, expected, directive, line)
        return if node.type == expected

        raise ParseError.new("'#{directive}' is only valid in interface type '#{expected}', got '#{node.type}'", line: line.number)
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
          expect_token_count(line, 2, "description <string>")
          node.description = expect_word_or_string(line.tokens[1], "description")
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
          if line.head.value == "type"
            parse_block_type_section(node, line)
            next
          end
          parse_block_field(node, line)
        end

        node
      end

      # Parse the `type <docker|shell> ... exit` sub-section. New Phase 12+
      # form. Old Phase 1-11 form (image/exec directly in block body) is
      # still parsed via parse_block_field for backward compatibility — when
      # `image` is set without an explicit type, we infer `docker`.
      def parse_block_type_section(node, header)
        expect_token_count(header, 2, "type <docker|shell>")
        kind = expect_word(header.tokens[1], "block type")
        unless AST::Block::EXECUTION_TYPES.include?(kind)
          raise ParseError.new(
            "invalid block type '#{kind}' (allowed: #{AST::Block::EXECUTION_TYPES.join(', ')})",
            line: header.number
          )
        end
        if node.execution_type
          raise ParseError.new("block '#{node.name}' already has a type section", line: header.number)
        end
        node.execution_type = kind
        advance

        each_body_line("type #{kind}") do |line|
          case kind
          when "docker" then apply_docker_type_field(node, line)
          when "shell"  then apply_shell_type_field(node, line)
          end
        end
      end

      def apply_docker_type_field(node, line)
        head = line.head.value
        case head
        when "image"
          expect_token_count(line, 2, "image <reference>")
          node.image = expect_word_or_string(line.tokens[1], "image reference")
        when "command"
          expect_min_tokens(line, 2, "command <args...>")
          node.command = line.tokens[1..].map(&:value).join(" ")
        when "pull"
          expect_token_count(line, 2, "pull <#{AST::Block::PULL_VALUES.join('|')}>")
          value = expect_word(line.tokens[1], "pull policy")
          unless AST::Block::PULL_VALUES.include?(value)
            raise ParseError.new("invalid pull '#{value}' (allowed: #{AST::Block::PULL_VALUES.join(', ')})", line: line.number)
          end
          node.pull = value
        when "network"
          expect_token_count(line, 2, "network <on|off>")
          value = expect_word(line.tokens[1], "network")
          unless AST::Block::NETWORK_VALUES.include?(value)
            raise ParseError.new("invalid network value '#{value}' (allowed: on, off)", line: line.number)
          end
          node.network = value
        when "user"
          expect_token_count(line, 2, "user <user>")
          node.user = expect_word_or_string(line.tokens[1], "user")
        when "memory"
          expect_token_count(line, 2, "memory <limit>")
          node.memory = expect_word_or_string(line.tokens[1], "memory")
        when "cpu"
          expect_token_count(line, 2, "cpu <limit>")
          node.cpu = expect_word_or_string(line.tokens[1], "cpu")
        else
          raise ParseError.new("unknown directive '#{head}' in 'type docker' block", line: line.number)
        end
      end

      def apply_shell_type_field(node, line)
        head = line.head.value
        case head
        when "exec"
          expect_min_tokens(line, 2, "exec <command>")
          node.shell_exec = line.tokens[1..].map(&:value).join(" ")
        when "cwd"
          expect_token_count(line, 2, "cwd <path>")
          node.shell_cwd = expect_word_or_string(line.tokens[1], "cwd")
        when "shell"
          expect_token_count(line, 2, "shell <path>")
          node.shell_path = expect_word_or_string(line.tokens[1], "shell")
        when "env"
          expect_token_count(line, 3, "env <KEY> <VALUE>")
          key = expect_word(line.tokens[1], "env key")
          value = expect_word_or_string(line.tokens[2], "env value")
          node.shell_env[key] = value
        else
          raise ParseError.new("unknown directive '#{head}' in 'type shell' block", line: line.number)
        end
      end

      def parse_block_field(node, line)
        head = line.head.value

        case head
        # ---- Phase 1-11 inline shape: image/command/network are accepted
        # directly inside `block` (without a `type docker` wrapper). The
        # block's execution_type is inferred as 'docker' when `image` lands.
        when "image"
          expect_token_count(line, 2, "image <reference>")
          node.image = expect_word_or_string(line.tokens[1], "image reference")
          node.execution_type ||= "docker"
        when "command"
          expect_min_tokens(line, 2, "command <args...>")
          node.command = line.tokens[1..].map(&:value).join(" ")
        when "network"
          expect_token_count(line, 2, "network <on|off>")
          value = expect_word(line.tokens[1], "network")
          unless AST::Block::NETWORK_VALUES.include?(value)
            raise ParseError.new("invalid network value '#{value}' (allowed: on, off)", line: line.number)
          end
          node.network = value
        # ---- Common block fields
        when "timeout"
          expect_token_count(line, 2, "timeout <duration>")
          node.timeout_ms = expect_duration(line.tokens[1], "timeout")
        when "retry"
          # Two accepted forms:
          #   retry policy <name>   (Phase 1 verbose)
          #   retry <name>          (Phase 12 short)
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
          expect_token_count(line, 2, "input <context.path>")
          node.input = expect_context_path(line.tokens[1], "input")
        when "output"
          expect_token_count(line, 2, "output <context.path>")
          node.output = expect_context_path(line.tokens[1], "output")
        # ---- enable/disable: spec §3 shorthand for shutdown semantics.
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
          raise ParseError.new("unknown directive '#{head}' in block", line: line.number)
        end
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
