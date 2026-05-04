require_relative "../util/duration_parser"
require_relative "../runner/registry"

module Prouterd
  module Config
    # Renders an AST::Document into canonical .prc text.
    #
    # The output is the source of truth for `show running-config`, diffing,
    # commit snapshots, and audit. Top-level sections appear in canonical order
    # (router → secrets → policies → queues → interfaces → processes → global
    # routes); items within a section preserve declaration order so user intent
    # is visible.
    class Renderer
      INDENT = " ".freeze

      def self.render(document)
        new(document).render
      end

      def initialize(document)
        @doc = document
        @lines = []
      end

      def render
        render_router(@doc.router) if @doc.router
        @doc.secrets.each   { |s| blank; render_secret(s) }
        @doc.policies.each  { |p| blank; render_policy(p) }
        @doc.queues.each    { |q| blank; render_queue(q) }
        @doc.contracts.each { |c| blank; render_contract(c) }
        @doc.interfaces.each { |i| blank; render_interface(i) }
        @doc.processes.each { |p| blank; render_process(p) }
        @doc.global_routes.each { |r| blank; render_global_route(r) }
        @lines.join("\n") + (@lines.empty? ? "" : "\n")
      end

      private

      def emit(level, text)
        @lines << (INDENT * level) + text
      end

      def blank
        @lines << "" unless @lines.empty?
      end

      def render_router(router)
        emit(0, "router #{router.name}")
        emit(1, "version #{router.version}") if router.version
        emit(1, "hostname #{quote_if_needed(router.hostname)}") if router.hostname
        emit(0, "exit")
      end

      def render_secret(secret)
        emit(0, "secret #{secret.name}")
        emit(1, "source #{secret.source_type} #{secret.source_value}") if secret.source_type
        emit(0, "exit")
      end

      def render_policy(policy)
        emit(0, "policy #{policy.name}")
        emit(1, "retry attempts #{policy.retry_attempts}") if policy.retry_attempts
        emit(1, "retry backoff #{policy.retry_backoff}") if policy.retry_backoff
        emit(1, "retry initial-delay #{Util::DurationParser.render(policy.retry_initial_delay_ms)}") if policy.retry_initial_delay_ms
        emit(1, "retry max-delay #{Util::DurationParser.render(policy.retry_max_delay_ms)}") if policy.retry_max_delay_ms
        emit(1, "timeout #{Util::DurationParser.render(policy.timeout_ms)}") if policy.timeout_ms
        emit(0, "exit")
      end

      def render_queue(queue)
        emit(0, "queue #{queue.name}")
        emit(1, "concurrency #{queue.concurrency}") if queue.concurrency
        emit(1, "timeout #{Util::DurationParser.render(queue.timeout_ms)}") if queue.timeout_ms
        emit(0, "exit")
      end

      def render_interface(iface)
        emit(0, "interface #{iface.type} #{iface.name}")
        case iface.type
        when "webhook"
          emit(1, "path #{iface.path}") if iface.path
          emit(1, "method #{iface.method}") if iface.method
          if iface.auth
            emit(1, "auth #{iface.auth.scheme} secret #{iface.auth.secret_name}")
          end
        when "cron"
          emit(1, "schedule #{quote_if_needed(iface.schedule)}") if iface.schedule
          emit(1, "timezone #{quote_if_needed(iface.timezone)}") if iface.timezone
        end
        emit(1, iface.shutdown ? "shutdown" : "no shutdown")
        emit(0, "exit")
      end

      def render_process(process)
        emit(0, "process #{process.name}")
        emit(1, "description #{quote_if_needed(process.description)}") if process.description
        emit(1, "queue #{process.queue_name}") if process.queue_name
        emit(1, process.shutdown ? "shutdown" : "no shutdown")

        process.blocks.each do |block|
          @lines << ""
          render_block(block, 1)
        end

        unless process.routes.empty?
          @lines << ""
          process.routes.each { |route| render_process_route(route, 1) }
        end

        emit(0, "exit")
      end

      def render_block(block, level)
        emit(level, "block #{block.name}")

        plugin = Runner::Registry.lookup(block.execution_type)
        render_type_section(plugin, block, level + 1) if plugin

        # Common block fields, post-type, in spec order
        emit(level + 1, "input #{block.input}") if block.input
        block.artifact_inputs.each do |ai|
          emit(level + 1, "input from #{ai.from_block}.#{ai.from_artifact}")
        end
        emit(level + 1, "output #{block.output}") if block.output
        block.produces.each { |p| emit(level + 1, "produces #{p}") }
        emit(level + 1, "timeout #{Util::DurationParser.render(block.timeout_ms)}") if block.timeout_ms
        emit(level + 1, "retry #{block.retry_policy_name}") if block.retry_policy_name
        emit(level + 1, "contract #{block.contract_name}") if block.contract_name
        block.secret_names.each { |name| emit(level + 1, "secret #{name}") }
        # enable/disable shorthand for shutdown (block-level only).
        emit(level + 1, block.shutdown ? "disable" : "enable")
        emit(level, "exit")
      end

      # Generic per-plugin renderer. Walks the plugin's declared fields in
      # declaration order so the canonical output is stable across runs.
      def render_type_section(plugin, block, level)
        emit(level, "type #{plugin.type_name}")
        plugin.fields.each do |field|
          value = block.type_fields[field.storage_key]
          next if skip_value?(value, field)

          case field.kind
          when :string
            emit(level + 1, "#{field.dsl_keyword} #{quote_if_needed(value)}")
          when :enum
            emit(level + 1, "#{field.dsl_keyword} #{value}")
          when :command
            # Always quote — embedded shell metacharacters would otherwise
            # be lost on re-parse since the lexer re-tokenizes whitespace.
            emit(level + 1, "#{field.dsl_keyword} #{quote_string(value)}")
          when :env_pair
            value.each do |k, v|
              emit(level + 1, "#{field.dsl_keyword} #{k} #{quote_if_needed(v)}")
            end
          end
        end
        emit(level, "exit")
      end

      def skip_value?(value, field)
        return true if value.nil?
        return true if value.respond_to?(:empty?) && value.empty?
        return true if !field.default.nil? && value == field.default

        false
      end

      def render_process_route(route, level)
        if route_has_body?(route)
          emit(level, "route #{route.from_block} #{route.to_block}")
          route.matches.each { |m| emit(level + 1, render_match(m)) }
          emit(level + 1, "on-failure #{route.on_failure}") if route.on_failure && route.on_failure != "stop"
          emit(level + 1, "shutdown") if route.shutdown
          emit(level, "exit")
        else
          emit(level, "route #{route.from_block} #{route.to_block}")
        end
      end

      def route_has_body?(route)
        !route.matches.empty? ||
          (route.on_failure && route.on_failure != "stop") ||
          route.shutdown
      end

      def render_global_route(route)
        emit(0, "route interface #{route.interface_name} process #{route.process_name}")
        route.matches.each { |m| emit(1, render_match(m)) }
        emit(0, "exit")
      end

      def render_contract(contract)
        emit(0, "contract #{contract.name}")
        contract.requirements.each do |req|
          # Emit one line per Requirement, packing all attributes inline
          # so the canonical form stays grep-friendly.
          keyword = req.required ? "require" : "optional"
          parts = ["#{keyword} #{req.path}"]
          parts << "type #{req.type}" if req.type
          parts << "min #{req.min}" if req.min
          parts << "max #{req.max}" if req.max
          parts << "length #{req.length}" if req.length
          parts << "min-length #{req.min_length}" if req.min_length
          parts << "max-length #{req.max_length}" if req.max_length
          parts << "format #{req.format}" if req.format
          parts << "pattern #{quote_string(req.pattern)}" if req.pattern
          parts << "in #{req.enum.map { |v| render_value(v) }.join(',')}" if req.enum
          emit(1, parts.join(" "))
        end
        emit(1, "on violation #{contract.on_violation}") if contract.on_violation && contract.on_violation != "fail"
        emit(0, "exit")
      end

      def render_match(match)
        case match.operator
        when "exists"
          "match #{match.path} exists"
        when "in"
          "match #{match.path} in #{match.values.map { |v| render_value(v) }.join(',')}"
        else
          "match #{match.path} #{match.operator} #{render_value(match.values.first)}"
        end
      end

      # In match value position we always quote strings — the lexer treats
      # bare words and quoted strings identically, so quoting eliminates any
      # visual ambiguity with numbers, paths, or keywords in canonical output.
      def render_value(value)
        case value
        when String
          %("#{escape_string(value)}")
        when true, false, Integer, Float
          value.to_s
        else
          value.to_s
        end
      end

      # In free-text positions (description, hostname, schedule, timezone) we
      # only quote when needed: empty string, contains whitespace/quotes/comments,
      # or starts with a digit (which a re-parser would coerce to a number).
      def quote_if_needed(text)
        return text unless text.is_a?(String)
        return %("#{escape_string(text)}") if text.empty? || text.match?(/[\s"!#]/) || text.match?(/\A[+-]?\d/)

        text
      end

      def quote_string(text)
        %("#{escape_string(text)}")
      end

      def escape_string(text)
        text.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
      end
    end
  end
end
