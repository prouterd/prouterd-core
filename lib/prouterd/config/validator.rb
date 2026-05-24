# frozen_string_literal: true

require "set"
require_relative "../iface/registry"

module Prouterd
  module Config
    # Validates a parsed AST::Document. Returns a Result with errors and warnings.
    #
    # Errors block commits; warnings are advisory. Each finding carries the
    # source line so the CLI can report `line N: message`.
    class Validator
      Issue = Struct.new(:level, :line, :message) do
        def to_s
          line ? "line #{line}: #{message}" : message.to_s
        end
      end

      class Result
        attr_reader :errors, :warnings

        def initialize
          @errors = []
          @warnings = []
        end

        def error(message, line: nil)
          @errors << Issue.new(:error, line, message)
        end

        def warning(message, line: nil)
          @warnings << Issue.new(:warning, line, message)
        end

        def valid?
          @errors.empty?
        end
      end

      def self.validate(document)
        new(document).validate
      end

      def initialize(document)
        @doc = document
        @result = Result.new
      end

      # Top-level collections that share the "duplicate <kind> '<name>'"
      # uniqueness check. Order matches the validate sequence below — we
      # check uniqueness of every collection before doing per-item
      # semantic checks so duplicates surface as their own errors.
      UNIQUE_COLLECTIONS = {
        secrets:    "secret",
        policies:   "policy",
        queues:     "queue",
        interfaces: "interface",
        processes:  "process",
        contracts:  "contract",
        tools:      "tool"
      }.freeze

      def validate
        check_router
        UNIQUE_COLLECTIONS.each { |coll, kind| check_unique(@doc.public_send(coll), kind) }
        check_secret_sources
        check_policies
        check_queues
        check_interfaces
        check_contracts
        check_tools
        check_processes
        check_global_routes
        @result
      end

      def check_tools
        @doc.tools.each do |tool|
          impl = tool.implementation
          unless impl
            @result.error("tool '#{tool.name}' missing `implementation` directive", line: tool.line)
            next
          end
          iface = @doc.interfaces.find { |i| i.name == impl.iface_name && i.type == impl.iface_type }
          unless iface
            @result.error(
              "tool '#{tool.name}' implementation references undeclared interface '#{impl.iface_type} #{impl.iface_name}'",
              line: tool.line
            )
          end
        end
      end

      private

      def check_router
        return if @doc.router

        @result.error("missing 'router' declaration")
      end

      def check_unique(items, kind)
        seen = {}
        items.each do |item|
          if seen.key?(item.name)
            @result.error("duplicate #{kind} '#{item.name}' (first defined at line #{seen[item.name]})", line: item.line)
          else
            seen[item.name] = item.line
          end
        end
      end

      def check_secret_sources
        @doc.secrets.each do |secret|
          if secret.source_type.nil?
            @result.error("secret '#{secret.name}' missing 'source' directive", line: secret.line)
          end
        end
      end

      def check_policies
        @doc.policies.each do |policy|
          if policy.retry_attempts.nil? && policy.timeout_ms.nil?
            @result.warning("policy '#{policy.name}' has no retry or timeout settings", line: policy.line)
          end
          if policy.retry_attempts && policy.retry_backoff.nil?
            @result.error("policy '#{policy.name}' has 'retry attempts' but no 'retry backoff'", line: policy.line)
          end
          if policy.retry_initial_delay_ms && policy.retry_max_delay_ms &&
             policy.retry_initial_delay_ms > policy.retry_max_delay_ms
            @result.error("policy '#{policy.name}': retry initial-delay exceeds max-delay", line: policy.line)
          end
        end
      end

      def check_queues
        @doc.queues.each do |queue|
          if queue.concurrency.nil?
            @result.error("queue '#{queue.name}' missing 'concurrency'", line: queue.line)
          end
        end
      end

      def check_interfaces
        @doc.interfaces.each do |iface|
          plugin = Iface::Registry.lookup(iface.type)
          unless plugin
            @result.error(
              "interface '#{iface.name}' has unknown type '#{iface.type}'",
              line: iface.line
            )
            next
          end

          # Required-field check, driven off the plugin schema.
          plugin.fields.each do |field|
            next unless field.required

            value = iface.type_fields[field.storage_key]
            if value.nil? || (value.respond_to?(:empty?) && value.empty?)
              @result.error(
                "interface '#{iface.name}' (#{plugin.type_name}) missing '#{field.dsl_keyword}'",
                line: iface.line
              )
            end
          end

          # Plugin-specific cross-field validation (e.g. webhook `auth`
          # references an existing secret).
          plugin.validate(iface, @doc, @result)
        end
      end

      def check_processes
        @doc.processes.each do |process|
          check_process(process)
        end
      end

      def check_process(process)
        if process.blocks.empty?
          @result.error("process '#{process.name}' has no blocks", line: process.line)
          return
        end

        check_unique_blocks(process)
        check_blocks(process)

        if process.queue_name && !queue_defined?(process.queue_name)
          @result.error("process '#{process.name}' references unknown queue '#{process.queue_name}'", line: process.line)
        end

        check_process_routes(process)
        check_process_graph(process)
        check_merge_groups(process)
      end

      def check_merge_groups(process)
        block_names = process.blocks.map(&:name).to_set
        process.merge_groups.each do |group|
          group.member_block_names.each do |member|
            # Members must be real blocks in the same process, and must
            # not be barriers themselves — barrier→barrier coupling is
            # legal at the graph level but turns the merge semantics
            # into "merge of merges", which we don't expand here. Force
            # the operator to introduce an explicit intermediate block
            # if they want that chain.
            target = process.block(member)
            unless block_names.include?(member)
              @result.error(
                "merge '#{process.name}/#{group.name}' references unknown member block '#{member}'",
                line: group.line
              )
              next
            end
            if target&.barrier?
              @result.error(
                "merge '#{process.name}/#{group.name}' member '#{member}' is itself a barrier block; chain through an intermediate block",
                line: group.line
              )
            end
          end
        end
      end

      def check_unique_blocks(process)
        seen = {}
        process.blocks.each do |block|
          if seen.key?(block.name)
            @result.error("duplicate block '#{block.name}' in process '#{process.name}' (first at line #{seen[block.name]})", line: block.line)
          else
            seen[block.name] = block.line
          end
        end
      end

      def check_blocks(process)
        process.blocks.each do |block|
          check_block_type(process, block)

          if block.retry_policy_name && !policy_defined?(block.retry_policy_name)
            @result.error("block '#{process.name}/#{block.name}' references unknown policy '#{block.retry_policy_name}'", line: block.line)
          end
          block.secret_names.each do |secret_name|
            unless secret_defined?(secret_name)
              @result.error("block '#{process.name}/#{block.name}' references unknown secret '#{secret_name}'", line: block.line)
            end
          end
          if block.contract_name && !contract_defined?(block.contract_name)
            @result.error("block '#{process.name}/#{block.name}' references unknown contract '#{block.contract_name}'", line: block.line)
          end
          if block.fan_out? && !@doc.processes.any? { |p| p.name == block.fan_out_into }
            @result.error("block '#{process.name}/#{block.name}' fan-out targets unknown process '#{block.fan_out_into}'", line: block.line)
          end
          if block.agentic
            iface_ref = block.interface_ref
            # Anthropic HTTP + Codex CLI subprocess support full
            # multi-turn agentic loop. Claude Code CLI's `-p` mode
            # is one-shot; multi-turn would need --resume chaining
            # which the current driver doesn't speak. Use HTTP
            # provider="anthropic" for agentic against Claude.
            agentic_providers = %w[anthropic codex_cli]
            if iface_ref && iface_ref.type == "llm"
              iface = @doc.interfaces.find { |i| i.type == "llm" && i.name == iface_ref.name }
              provider = iface&.type_fields&.[]("provider")
              if iface && provider == "claude_cli"
                @result.error(
                  "block '#{process.name}/#{block.name}': `agentic on` is not supported with `provider claude_cli` " \
                  "(Claude Code CLI's `-p` mode is one-shot; for multi-turn agentic against Claude, " \
                  "use `provider anthropic` HTTP instead)",
                  line: block.line
                )
              elsif iface && !agentic_providers.include?(provider)
                @result.error(
                  "block '#{process.name}/#{block.name}': `agentic on` supports providers #{agentic_providers.join('/')} on the referenced interface (got '#{provider}')",
                  line: block.line
                )
              end
            else
              @result.error("block '#{process.name}/#{block.name}': `agentic on` requires `interface llm <name>`", line: block.line)
            end
            block.mcp_refs.each do |iface_name|
              iface = @doc.interfaces.find { |i| i.name == iface_name }
              if iface.nil? || iface.type != "mcp"
                @result.error(
                  "block '#{process.name}/#{block.name}' mcp references " \
                  "undeclared interface '#{iface_name}' (must be `interface mcp <name>`)",
                  line: block.line
                )
              end
            end
            block.allowed_tools.each do |tool_name|
              if tool_name.include?(".")
                # Namespaced — head must be a declared `interface mcp`.
                # Tail (the actual tool name) is forward-declared,
                # validated at daemon connect when tools/list arrives.
                ns = tool_name.split(".", 2).first
                iface = @doc.interfaces.find { |i| i.name == ns }
                if iface.nil? || iface.type != "mcp"
                  @result.error(
                    "block '#{process.name}/#{block.name}' allowed-tools '#{tool_name}': " \
                    "namespace '#{ns}' is not a declared `interface mcp`",
                    line: block.line
                  )
                elsif !block.mcp_refs.include?(ns)
                  @result.error(
                    "block '#{process.name}/#{block.name}' allowed-tools '#{tool_name}': " \
                    "namespace '#{ns}' is not in this block's `mcp` list",
                    line: block.line
                  )
                end
              else
                unless @doc.tools.any? { |t| t.name == tool_name }
                  @result.error(
                    "block '#{process.name}/#{block.name}' allowed-tools references undeclared tool '#{tool_name}'",
                    line: block.line
                  )
                end
              end
            end
          end
        end

        check_artifact_flow(process)
      end

      # Verify every `input from Y.Z`:
      #   - Y is a block in this process
      #   - Y declares `produces Z`
      #   - Y is reachable upstream of this block (path Y -> ... -> block)
      #   - within a block, no two inputs derive the same local name
      def check_artifact_flow(process)
        block_index = process.blocks.each_with_object({}) { |b, h| h[b.name] = b }
        adjacency = Hash.new { |h, k| h[k] = [] }
        process.routes.each do |r|
          adjacency[r.from_block] << r.to_block if block_index.key?(r.from_block) && block_index.key?(r.to_block)
        end

        process.blocks.each do |block|
          check_artifact_input_collisions(process, block)
          block.artifact_inputs.each do |ai|
            upstream = block_index[ai.from_block]
            unless upstream
              @result.error(
                "block '#{process.name}/#{block.name}' input '#{ai.local_name}' references unknown block '#{ai.from_block}'",
                line: ai.line
              )
              next
            end
            unless upstream.produces.include?(ai.from_artifact)
              @result.error(
                "block '#{process.name}/#{block.name}' input '#{ai.local_name}' references " \
                "'#{ai.from_block}.#{ai.from_artifact}' but '#{ai.from_block}' does not declare " \
                "'produces #{ai.from_artifact}'",
                line: ai.line
              )
              next
            end
            unless reachable_upstream?(adjacency, ai.from_block, block.name)
              @result.error(
                "block '#{process.name}/#{block.name}' consumes artifact from '#{ai.from_block}' " \
                "but '#{ai.from_block}' is not upstream in the route graph",
                line: ai.line
              )
            end
          end
        end
      end

      # Two inputs that derive the same local name would collide in
      # /prouter/inputs/<local> and PROUTER_INPUT_<UPPER>. Report the
      # second occurrence with a fix-it pointer.
      def check_artifact_input_collisions(process, block)
        seen = {}
        block.artifact_inputs.each do |ai|
          name = ai.local_name
          if (prev = seen[name])
            @result.error(
              "block '#{process.name}/#{block.name}': inputs '#{prev.from_block}.#{prev.from_artifact}' " \
              "and '#{ai.from_block}.#{ai.from_artifact}' both derive local name '#{name}'; " \
              "rename one of them in the upstream block's `produces`",
              line: ai.line
            )
          else
            seen[name] = ai
          end
        end
      end

      def reachable_upstream?(adjacency, from, target)
        return false if from == target

        visited = Set.new
        queue = [from]
        until queue.empty?
          node = queue.shift
          next unless visited.add?(node)
          return true if adjacency[node].include?(target)

          adjacency[node].each { |n| queue << n }
        end
        false
      end

      def check_block_type(process, block)
        # Pause-blocks have no interface dispatch — execution halts at
        # them and the run goes to status="paused" until `prouter resume`
        # injects an output. They legally have no `interface` directive.
        return if block.pause?
        # Synthesized barrier blocks (from `parallel <name>` expansion)
        # are no-op aggregators — they have no interface either.
        return if block.barrier?

        # Every other block must reference an outbound interface via
        # `interface <type> <name>` in its body.
        ref = block.interface_ref
        unless ref
          @result.error(
            "block '#{process.name}/#{block.name}' missing `interface <type> <name>` directive",
            line: block.line
          )
          return
        end

        plugin = Iface::Registry.lookup(ref.type)
        unless plugin
          @result.error(
            "block '#{process.name}/#{block.name}' references unknown interface type '#{ref.type}'",
            line: ref.line
          )
          return
        end

        unless plugin.outbound?
          @result.error(
            "block '#{process.name}/#{block.name}' references '#{ref.type}' interface, " \
            "but '#{ref.type}' is #{plugin.direction} (only outbound interfaces are usable from blocks)",
            line: ref.line
          )
          return
        end

        unless plugin.block_callable?
          @result.error(
            "block '#{process.name}/#{block.name}' references '#{ref.type}' interface, " \
            "but '#{ref.type}' is runtime-only; use it through an agentic llm block's `mcp #{ref.name}` directive",
            line: ref.line
          )
          return
        end

        iface = collection_index(:interfaces)[ref.name]
        unless iface
          @result.error(
            "block '#{process.name}/#{block.name}' references unknown interface '#{ref.name}'",
            line: ref.line
          )
          return
        end

        unless iface.type == ref.type
          @result.error(
            "block '#{process.name}/#{block.name}' says `interface #{ref.type} #{ref.name}` " \
            "but '#{ref.name}' is declared as type '#{iface.type}'",
            line: ref.line
          )
          return
        end

        # Required call-fields per plugin schema.
        plugin.call_fields.each do |field|
          next unless field.required

          value = block.type_fields[field.storage_key]
          if value.nil? || (value.respond_to?(:empty?) && value.empty?)
            @result.error(
              "block '#{process.name}/#{block.name}' (interface #{plugin.type_name} #{ref.name}) " \
              "missing call-field '#{field.dsl_keyword}'",
              line: block.line
            )
          end
        end
      end

      def check_process_routes(process)
        block_names = process.blocks.map(&:name).to_set
        seen_pairs = {}

        process.routes.each do |route|
          unless block_names.include?(route.from_block)
            @result.error("route in '#{process.name}' references unknown from-block '#{route.from_block}'", line: route.line)
          end
          unless block_names.include?(route.to_block)
            @result.error("route in '#{process.name}' references unknown to-block '#{route.to_block}'", line: route.line)
          end
          if route.from_block == route.to_block
            @result.error("route '#{route.from_block} -> #{route.to_block}' is a self-loop", line: route.line)
          end

          pair = [route.from_block, route.to_block]
          if seen_pairs.key?(pair)
            @result.error("duplicate route '#{route.from_block} -> #{route.to_block}' in '#{process.name}' (first at line #{seen_pairs[pair]})", line: route.line)
          else
            seen_pairs[pair] = route.line
          end

          route.matches.each { |m| check_match(m) }
        end

        check_single_incoming(process)
      end

      def check_single_incoming(process)
        incoming = Hash.new { |h, k| h[k] = [] }
        process.routes.each do |route|
          incoming[route.to_block] << route
        end
        block_index = process.blocks.each_with_object({}) { |b, h| h[b.name] = b }
        incoming.each do |block_name, routes|
          # Synthesized barrier blocks for `parallel <name>` legitimately
          # have multiple incoming routes (one per member). Skip the
          # join check for them.
          next if block_index[block_name]&.barrier?

          if routes.length > 1
            lines = routes.map(&:line).join(", ")
            @result.error(
              "block '#{process.name}/#{block_name}' has multiple incoming routes (lines #{lines}); join semantics are not supported in MVP — introduce a merge block or wrap the upstreams in a `parallel` group instead",
              line: routes.first.line
            )
          end
        end
      end

      def check_process_graph(process)
        block_names = process.blocks.map(&:name)

        adjacency = Hash.new { |h, k| h[k] = [] }
        process.routes.each do |route|
          next unless block_names.include?(route.from_block) && block_names.include?(route.to_block)

          adjacency[route.from_block] << route.to_block
        end

        if (cycle = find_cycle(block_names, adjacency))
          @result.error("process '#{process.name}' contains a cycle: #{cycle.join(' -> ')}", line: process.line)
          return
        end

        incoming = Hash.new(0)
        process.routes.each do |route|
          next unless block_names.include?(route.to_block)

          incoming[route.to_block] += 1
        end
        entry_blocks = block_names.reject { |name| incoming[name].positive? }

        if entry_blocks.empty?
          @result.error("process '#{process.name}' has no entry block (every block has incoming routes)", line: process.line)
        end

        # Reachability: every block must be reachable from some entry block.
        reachable = entry_blocks.dup.to_set
        queue = entry_blocks.dup
        until queue.empty?
          current = queue.shift
          adjacency[current].each do |neighbor|
            unless reachable.include?(neighbor)
              reachable << neighbor
              queue << neighbor
            end
          end
        end
        unreachable = block_names - reachable.to_a
        unreachable.each do |name|
          block = process.block(name)
          @result.warning("block '#{process.name}/#{name}' is unreachable from any entry block", line: block&.line)
        end
      end

      def find_cycle(block_names, adjacency)
        color = {}
        path = []

        block_names.each do |start|
          next if color[start] == :black

          stack = [[start, adjacency[start].dup]]
          color[start] = :gray
          path << start

          until stack.empty?
            _node, neighbors = stack.last
            if neighbors.empty?
              finished = stack.pop[0]
              color[finished] = :black
              path.pop
              next
            end

            neighbor = neighbors.shift
            case color[neighbor]
            when :gray
              cycle_start = path.index(neighbor)
              return path[cycle_start..] + [neighbor] if cycle_start
            when nil
              color[neighbor] = :gray
              path << neighbor
              stack << [neighbor, adjacency[neighbor].dup]
            end
          end
        end

        nil
      end

      def check_match(match)
        # Static-time match validity is largely guaranteed by the parser;
        # nothing structural to check here yet. Reserved for future checks
        # (e.g. type inference against output schemas).
        _ = match
      end

      def check_global_routes
        process_names = @doc.processes.map(&:name).to_set
        interface_names = @doc.interfaces.map(&:name).to_set
        seen_pairs = {}

        @doc.global_routes.each do |route|
          unless interface_names.include?(route.interface_name)
            @result.error("global route references unknown interface '#{route.interface_name}'", line: route.line)
          end
          unless process_names.include?(route.process_name)
            @result.error("global route references unknown process '#{route.process_name}'", line: route.line)
          end

          pair = [route.interface_name, route.process_name]
          if seen_pairs.key?(pair)
            @result.error("duplicate global route '#{route.interface_name} -> #{route.process_name}' (first at line #{seen_pairs[pair]})", line: route.line)
          else
            seen_pairs[pair] = route.line
          end
        end
      end

      # ----- lookup helpers -----
      #
      # Single generic `defined?` over a top-level collection. Pure
      # Hash#has_key? after a lazy-built index — O(1) per check instead
      # of O(n) `Array#any?` for every block-level secret/policy/
      # contract/queue reference. The index is per-validate-call, so a
      # subsequent validate of a different document sees a fresh map.

      def secret_defined?(name);   collection_index(:secrets).key?(name);   end
      def policy_defined?(name);   collection_index(:policies).key?(name);  end
      def queue_defined?(name);    collection_index(:queues).key?(name);    end
      def contract_defined?(name); collection_index(:contracts).key?(name); end

      def collection_index(coll)
        (@collection_indices ||= {})[coll] ||=
          @doc.public_send(coll).each_with_object({}) { |item, h| h[item.name] = item }
      end

      # ----- contract validation -----

      def check_contracts
        @doc.contracts.each do |contract|
          # Each Requirement should have at least a presence rule (required:
          # true) OR a constraint. A pure `optional <path>` with no extras
          # is meaningless and probably a typo.
          contract.requirements.each do |req|
            unless req.required || req.has_constraints?
              @result.warning(
                "contract '#{contract.name}': 'optional #{req.path}' has no constraints (no-op)",
                line: req.line
              )
            end
            check_requirement_consistency(contract, req)
          end
        end
      end

      def check_requirement_consistency(contract, req)
        # min/max only meaningful for numeric or string-via-length, but
        # we don't enforce that strictly — runtime ContractValidator
        # silently skips inapplicable rules. Catch here only the cases
        # where the user clearly wrote something contradictory.
        if req.min && req.max && req.min > req.max
          @result.error(
            "contract '#{contract.name}': '#{req.path}' min #{req.min} > max #{req.max}",
            line: req.line
          )
        end
        if req.min_length && req.max_length && req.min_length > req.max_length
          @result.error(
            "contract '#{contract.name}': '#{req.path}' min-length > max-length",
            line: req.line
          )
        end
        if req.format == "regex" && req.pattern.nil?
          @result.error(
            "contract '#{contract.name}': format 'regex' requires 'pattern <regex>'",
            line: req.line
          )
        end
      end
    end
  end
end
