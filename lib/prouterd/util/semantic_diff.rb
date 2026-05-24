# frozen_string_literal: true

module Prouterd
  module Util
    # Phase 36e: a structural diff between two AST::Document snapshots.
    # Used by `prouter validate <file> --against running` to answer:
    # "if I apply this file, what changes?". Operates on the parsed
    # AST so renames, reordering, and DSL form differences (backtick
    # vs double-quoted) don't show up as noise — only semantic changes.
    module SemanticDiff
      Change = Struct.new(:kind, :name, :reason, keyword_init: true) do
        def to_h_str
          { kind: kind.to_s, name: name, reason: reason }
        end
      end

      Result = Struct.new(:interfaces_added, :interfaces_removed, :interfaces_changed,
                          :processes_added, :processes_removed, :processes_changed,
                          :routes_added, :routes_removed,
                          :secrets_added, :secrets_removed,
                          :policies_added, :policies_removed, :policies_changed,
                          :queues_added, :queues_removed, :queues_changed,
                          keyword_init: true) do
        def empty?
          to_h.values.all?(&:empty?)
        end

        def total
          to_h.values.sum(&:length)
        end

        def to_json_payload
          to_h.transform_values { |v| v.map(&:to_h_str) }
        end
      end

      module_function

      def diff(left, right)
        Result.new(
          **diff_named_set(left.interfaces, right.interfaces, :interface, ->(i) { iface_signature(i) }),
          **diff_named_set(left.processes, right.processes, :process, ->(p) { process_signature(p) }),
          **diff_routes(left.global_routes, right.global_routes),
          **diff_secrets_or_policies_or_queues(left.secrets, right.secrets, :secret, ->(s) { [s.source_type, s.source_value] }),
          **diff_secrets_or_policies_or_queues(left.policies, right.policies, :policy, ->(p) { policy_signature(p) }),
          **diff_secrets_or_policies_or_queues(left.queues, right.queues, :queue, ->(q) { [q.concurrency, q.timeout_ms] })
        )
      end

      def diff_named_set(left_list, right_list, kind, signature_fn)
        left_by_name = left_list.each_with_object({}) { |x, h| h[x.name] = x }
        right_by_name = right_list.each_with_object({}) { |x, h| h[x.name] = x }
        added = (right_by_name.keys - left_by_name.keys).map do |name|
          Change.new(kind: kind, name: name, reason: "added")
        end
        removed = (left_by_name.keys - right_by_name.keys).map do |name|
          Change.new(kind: kind, name: name, reason: "removed")
        end
        changed = (left_by_name.keys & right_by_name.keys).filter_map do |name|
          ls = signature_fn.call(left_by_name[name])
          rs = signature_fn.call(right_by_name[name])
          next nil if ls == rs

          Change.new(kind: kind, name: name, reason: "changed: #{summarize_change(ls, rs)}")
        end
        # Result struct keys per kind:
        prefix = kind == :interface ? :interfaces : :processes
        { :"#{prefix}_added" => added, :"#{prefix}_removed" => removed, :"#{prefix}_changed" => changed }
      end

      def diff_routes(left_list, right_list)
        # Routes have no name — identify by (interface_name, process_name) tuple.
        signature = ->(r) { "#{r.interface_name}->#{r.process_name}" }
        left_set = left_list.map(&signature)
        right_set = right_list.map(&signature)
        added = (right_set - left_set).map do |sig|
          Change.new(kind: :route, name: sig, reason: "added")
        end
        removed = (left_set - right_set).map do |sig|
          Change.new(kind: :route, name: sig, reason: "removed")
        end
        { routes_added: added, routes_removed: removed }
      end

      def diff_secrets_or_policies_or_queues(left, right, kind, signature_fn)
        left_by_name = left.each_with_object({}) { |x, h| h[x.name] = x }
        right_by_name = right.each_with_object({}) { |x, h| h[x.name] = x }
        added = (right_by_name.keys - left_by_name.keys).map do |name|
          Change.new(kind: kind, name: name, reason: "added")
        end
        removed = (left_by_name.keys - right_by_name.keys).map do |name|
          Change.new(kind: kind, name: name, reason: "removed")
        end
        changed = (left_by_name.keys & right_by_name.keys).filter_map do |name|
          ls = signature_fn.call(left_by_name[name])
          rs = signature_fn.call(right_by_name[name])
          next nil if ls == rs

          Change.new(kind: kind, name: name, reason: "changed: #{summarize_change(ls, rs)}")
        end
        # `kind` is always one of :secret/:policy/:queue at the call
        # site — every caller of diff_secrets_or_policies_or_queues
        # passes a literal symbol.
        plural = { secret: :secrets, policy: :policies, queue: :queues }.fetch(kind)
        result = { :"#{plural}_added" => added, :"#{plural}_removed" => removed }
        result[:"#{plural}_changed"] = changed if kind != :secret
        result
      end

      def iface_signature(i)
        [i.type, i.shutdown, i.type_fields]
      end

      def process_signature(p)
        # Compare structural shape: blocks (name + interface_ref), routes,
        # queue, timeout. Anything that affects pipeline behaviour.
        blocks = p.blocks.map do |b|
          [b.name, b.interface_ref&.type, b.interface_ref&.name,
           b.timeout_ms, b.retry_policy_name, b.contract_name,
           b.shutdown, Array(b.secret_names).sort]
        end.sort
        routes = p.routes.map { |r| [r.from_block, r.to_block, r.on_failure] }.sort
        [p.queue_name, p.shutdown, p.timeout_ms, blocks, routes]
      end

      def policy_signature(p)
        [p.retry_attempts, p.retry_backoff, p.retry_initial_delay_ms,
         p.retry_max_delay_ms, p.timeout_ms,
         Array(p.retry_when_matches).map { |m| [m.path, m.operator, m.values] }.sort]
      end

      def summarize_change(left_sig, right_sig)
        if left_sig.length != right_sig.length || !left_sig.is_a?(Array)
          "shape changed"
        else
          left_sig.zip(right_sig).each_with_index.filter_map do |(l, r), idx|
            next nil if l == r

            "field[#{idx}]: #{l.inspect} -> #{r.inspect}"
          end.first || "shape changed"
        end
      end
    end
  end
end
