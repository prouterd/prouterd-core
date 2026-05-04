module Prouterd
  module Runtime
    # Evaluates AST::Match conditions against a runtime Context.
    #
    # Multiple matches inside a single Route AND together. nil-handling
    # rules:
    #
    #   exists       — true iff context has a non-nil value at path
    #   eq / neq     — work for any value (including nil)
    #   in           — value membership; missing path => false
    #   gt/gte/lt/lte — return false if either side is nil or non-comparable
    #
    # Type coercion: numeric values from the config DSL come through as
    # Integer/Float; runtime values may be Integer, Float, String, true/false,
    # nil, or nested Hashes/Arrays. Comparisons happen via Ruby's default <=>
    # rules so "5" gt 3 is false (string vs int — Ruby <=> returns nil).
    module MatchEvaluator
      module_function

      # All matches must pass for the route to fire.
      def passes?(matches, context)
        return true if matches.nil? || matches.empty?

        matches.all? { |m| evaluate(m, context) }
      end

      def evaluate(match, context)
        actual = context.get(match.path)
        case match.operator
        when "exists" then !actual.nil?
        when "eq"     then values_equal?(actual, match.values.first)
        when "neq"    then !values_equal?(actual, match.values.first)
        when "in"     then match.values.any? { |v| values_equal?(actual, v) }
        when "gt"     then numeric_compare(actual, match.values.first) == 1
        when "gte"    then [0, 1].include?(numeric_compare(actual, match.values.first))
        when "lt"     then numeric_compare(actual, match.values.first) == -1
        when "lte"    then [0, -1].include?(numeric_compare(actual, match.values.first))
        else
          raise ArgumentError, "unknown match operator '#{match.operator}'"
        end
      end

      # Evaluate a single match and return one of:
      #   true / false    — a definite result
      #   :runtime        — the path resolves to a value produced by a block
      #                     that hasn't run in this static walk yet
      #
      # This is what the Tracer uses: rather than crash on unknown values,
      # it surfaces "we can't tell yet" in the rendered trace.
      def static_evaluate(match, context, runtime_paths: [])
        actual = context.get(match.path)
        if runtime_paths.any? { |prefix| match.path == prefix || match.path.start_with?("#{prefix}.") }
          return :runtime
        end

        evaluate(match, context)
      rescue StandardError
        :runtime
      end

      def values_equal?(a, b)
        return true if a == b

        # Numeric cross-type tolerance: 1 == 1.0 is already true in Ruby.
        # String->number coercion is intentionally NOT done — type confusion
        # in pipelines is exactly the bug we want this evaluator to surface.
        false
      end

      def numeric_compare(a, b)
        return nil if a.nil? || b.nil?

        result = (a <=> b)
        return nil if result.nil?

        result
      end
    end
  end
end
