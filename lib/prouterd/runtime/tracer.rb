module Prouterd
  module Runtime
    # Static "what would happen" trace for an event without executing blocks.
    #
    # Builds a Result that the CLI/shell renders as plain text. The walker:
    #
    #   * Resolves the global route (matches event-only, fully evaluable)
    #   * Picks the target process
    #   * Walks the block DAG breadth-first
    #   * For each outgoing route, evaluates the match condition. Paths that
    #     resolve under "event.*" are evaluated against the supplied event.
    #     Paths under any block's `output` prefix that hasn't run yet in the
    #     walk are marked :runtime — we tell the user "depends on runtime".
    #   * Collects warnings about unreachable blocks, missing routes, etc.
    class Tracer
      Result = Struct.new(
        :interface,
        :event,
        :global_route,
        :global_route_passes,
        :process,
        :graph,
        :policies,
        :warnings,
        :error,
        keyword_init: true
      )

      EdgeAnnotation = Struct.new(:from, :to, :match_results, :passes, keyword_init: true)
      MatchAnnotation = Struct.new(:path, :operator, :values, :result, :reason, keyword_init: true)

      def self.trace(document, event, interface_name: nil)
        new(document, event, interface_name).trace
      end

      def initialize(document, event, interface_name)
        @document = document
        @event = event || {}
        @interface_name = interface_name
        @result = Result.new(
          interface: interface_name,
          event: @event,
          global_route: nil,
          global_route_passes: nil,
          process: nil,
          graph: [],
          policies: {},
          warnings: [],
          error: nil
        )
      end

      def trace
        return finalize_with_error("event must be a Hash") unless @event.is_a?(Hash)

        if @interface_name
          iface = @document.interfaces.find { |i| i.name == @interface_name }
          unless iface
            return finalize_with_error("unknown interface '#{@interface_name}'")
          end
          if iface.shutdown
            @result.warnings << "interface '#{@interface_name}' is shutdown — no event would actually be accepted"
          end
        end

        global = pick_global_route
        if global.nil?
          @result.warnings << "no global route matched the event"
          @result.global_route_passes = false
          return @result
        end

        process = @document.processes.find { |p| p.name == global[:route].process_name }
        unless process
          return finalize_with_error("global route targets unknown process '#{global[:route].process_name}'")
        end
        @result.process = process.name

        if process.shutdown
          @result.warnings << "process '#{process.name}' is shutdown — trigger would be no-op"
        end

        walk_process(process)
        collect_policies(process)
        @result
      end

      private

      def pick_global_route
        candidates = @document.global_routes
        candidates = candidates.select { |r| r.interface_name == @interface_name } if @interface_name

        candidates.each do |route|
          annotations = route.matches.map { |m| evaluate_match_against_event(m) }
          passes = annotations.all? { |a| a.result == true }
          @result.global_route = route
          @result.global_route_passes = passes
          if passes
            return { route: route, annotations: annotations }
          end
        end
        nil
      end

      def evaluate_match_against_event(match)
        # Global route matches reference event-only paths by construction.
        ctx = Context.new("event" => deep_stringify(@event))
        result = MatchEvaluator.static_evaluate(match, ctx, runtime_paths: [])
        MatchAnnotation.new(
          path: match.path,
          operator: match.operator,
          values: match.values,
          result: result,
          reason: result == :runtime ? "depends on runtime data" : nil
        )
      end

      def walk_process(process)
        runtime_paths = collect_runtime_paths(process)
        ctx = Context.new("event" => deep_stringify(@event))
        seen = Set.new
        queue = entry_blocks(process)

        @result.warnings << "process '#{process.name}' has no entry blocks" if queue.empty?

        until queue.empty?
          block_name = queue.shift
          next if seen.include?(block_name)

          seen << block_name
          block = process.block(block_name)
          next unless block

          process.routes.each do |route|
            next unless route.from_block == block_name

            target = process.block(route.to_block)
            next unless target

            annotations = route.matches.map do |m|
              MatchAnnotation.new(
                path: m.path,
                operator: m.operator,
                values: m.values,
                result: MatchEvaluator.static_evaluate(m, ctx, runtime_paths: runtime_paths),
                reason: depends_on_runtime?(m, runtime_paths) ? "depends on runtime output" : nil
              )
            end

            passes = annotations.all? { |a| a.result == true } # only counts definite trues
            depends = annotations.any? { |a| a.result == :runtime }
            verdict = depends ? :runtime : passes

            @result.graph << EdgeAnnotation.new(
              from: block_name,
              to: route.to_block,
              match_results: annotations,
              passes: verdict
            )

            queue << route.to_block unless seen.include?(route.to_block) || queue.include?(route.to_block)
          end
        end

        unreached = process.blocks.map(&:name) - seen.to_a
        unreached.each do |b|
          @result.warnings << "block '#{process.name}/#{b}' is unreachable from any entry block"
        end
      end

      def collect_runtime_paths(process)
        process.blocks.map(&:output).compact
      end

      def depends_on_runtime?(match, runtime_paths)
        runtime_paths.any? { |prefix| match.path == prefix || match.path.start_with?("#{prefix}.") }
      end

      def entry_blocks(process)
        with_incoming = process.routes.map(&:to_block).to_set
        process.blocks.reject { |b| with_incoming.include?(b.name) }.map(&:name)
      end

      def collect_policies(process)
        process.blocks.each do |block|
          summary = {}
          summary[:type] = block.execution_type if block.execution_type

          plugin = Prouterd::Runner::Registry.lookup(block.execution_type)
          if plugin
            plugin.fields.each do |field|
              value = block.type_fields[field.storage_key]
              next if value.nil?
              next if !field.default.nil? && value == field.default
              next if value.respond_to?(:empty?) && value.empty?

              summary[field.name] = value
            end
          end

          summary[:retry_policy] = block.retry_policy_name if block.retry_policy_name
          summary[:timeout_ms] = block.timeout_ms if block.timeout_ms
          summary[:contract] = block.contract_name if block.contract_name
          @result.policies[block.name] = summary unless summary.empty?
        end
      end

      def finalize_with_error(msg)
        @result.error = msg
        @result
      end

      def deep_stringify(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then value.map { |v| deep_stringify(v) }
        else            value
        end
      end
    end

    # Renders a Tracer::Result into the multi-line text form spec'd in §16.
    module TracerRenderer
      module_function

      def render(result)
        lines = []
        if result.error
          lines << "Trace error: #{result.error}"
          return lines.join("\n") + "\n"
        end

        lines << "Trace result"
        lines << ""
        lines << "Input interface:"
        lines << "  #{result.interface || '(manual / no interface filter)'}"
        lines << ""

        if result.global_route
          gr = result.global_route
          status = case result.global_route_passes
                   when true  then "matched"
                   when false then "did not match"
                   else            "depends on runtime"
                   end
          lines << "Matched global route:"
          lines << "  interface #{gr.interface_name} -> process #{gr.process_name}  (#{status})"
          gr.matches.each do |m|
            lines << "    match #{m.path} #{m.operator} #{format_values(m)}"
          end
          lines << ""
        else
          lines << "Matched global route:"
          lines << "  (no matching global route)"
          lines << ""
        end

        if result.process
          lines << "Selected process:"
          lines << "  #{result.process}"
          lines << ""
          lines << "Execution graph:"
          if result.graph.empty?
            lines << "  (no routes)"
          else
            result.graph.each do |edge|
              indicator = case edge.passes
                          when true  then ""
                          when false then "  ✗ skipped (condition false)"
                          else            "  ? depends on runtime"
                          end
              line = "  #{edge.from} -> #{edge.to}#{indicator}"
              lines << line
              edge.match_results.each do |m|
                marker = m.result == true ? "✓" : (m.result == false ? "✗" : "?")
                lines << "    #{marker} match #{m.path} #{m.operator} #{format_match_value(m)}#{m.reason ? "  (#{m.reason})" : ''}"
              end
            end
          end
          lines << ""
        end

        unless result.policies.empty?
          lines << "Policies:"
          result.policies.each do |block, summary|
            details = summary.map { |k, v| "#{k}=#{v}" }.join(", ")
            lines << "  #{block}: #{details}"
          end
          lines << ""
        end

        lines << "Warnings:"
        if result.warnings.empty?
          lines << "  none"
        else
          result.warnings.each { |w| lines << "  #{w}" }
        end

        lines.join("\n") + "\n"
      end

      def format_values(match)
        if match.operator == "exists"
          ""
        elsif match.operator == "in"
          match.values.map { |v| v.is_a?(String) ? v.inspect : v.to_s }.join(",")
        else
          v = match.values.first
          v.is_a?(String) ? v.inspect : v.to_s
        end
      end

      def format_match_value(annotation)
        if annotation.operator == "exists"
          ""
        elsif annotation.operator == "in"
          annotation.values.map { |v| v.is_a?(String) ? v.inspect : v.to_s }.join(",")
        else
          v = annotation.values.first
          v.is_a?(String) ? v.inspect : v.to_s
        end
      end
    end
  end
end
