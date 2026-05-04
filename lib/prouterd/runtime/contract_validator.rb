module Prouterd
  module Runtime
    # Runtime validator for contracts (Phase 14).
    #
    # The DSL `contract <name> ... exit` declares constraints over a
    # block's output JSON. After a block produces a non-nil output_json,
    # the orchestrator walks the contract's requirements and either
    # passes the value through, fails the run, retries, or warns —
    # depending on `on violation <fail|retry|warn>`.
    #
    # Supported constraints:
    #   * presence: `require` vs `optional`
    #   * type:     integer / number / string / boolean / array / object
    #   * range:    min / max (numerics)
    #   * length:   length / min-length / max-length (strings, arrays)
    #   * format:   email / uri / uuid / iso8601
    #   * pattern:  arbitrary regex (Ruby Regexp)
    #   * enum:     `in <v1>,<v2>,...`
    #
    # Returns an array of Violation structs. Empty array == OK.
    module ContractValidator
      Violation = Struct.new(:path, :kind, :detail, keyword_init: true) do
        def to_s
          base = "#{path}: #{kind}"
          detail ? "#{base} (#{detail})" : base
        end
      end

      EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/.freeze
      UUID_RE  = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze
      URI_RE   = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s]+\z}.freeze
      ISO8601_RE = /\A\d{4}-\d{2}-\d{2}(?:[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+\-]\d{2}:?\d{2})?)?\z/.freeze

      module_function

      def validate(contract, output)
        violations = []
        contract.requirements.each do |req|
          v = check_requirement(req, output)
          violations.concat(v) if v
        end
        violations
      end

      def check_requirement(req, output)
        value = dig(output, req.path)

        if value.nil?
          return [Violation.new(path: req.path, kind: :missing, detail: nil)] if req.required

          # Optional + absent: nothing to check.
          return []
        end

        violations = []

        if req.type
          unless type_match?(value, req.type)
            violations << Violation.new(
              path: req.path, kind: :wrong_type,
              detail: "expected #{req.type}, got #{ruby_type_name(value)}"
            )
            return violations # don't run further constraints on a wrong type
          end
        end

        # Numeric range — applies to Numeric values.
        if value.is_a?(Numeric)
          violations << Violation.new(path: req.path, kind: :below_min, detail: "min #{req.min}, got #{value}") if req.min && value < req.min
          violations << Violation.new(path: req.path, kind: :above_max, detail: "max #{req.max}, got #{value}") if req.max && value > req.max
        end

        # Length — applies to strings and arrays.
        if value.respond_to?(:length) && (req.length || req.min_length || req.max_length)
          len = value.length
          violations << Violation.new(path: req.path, kind: :wrong_length, detail: "expected #{req.length}, got #{len}") if req.length && len != req.length
          violations << Violation.new(path: req.path, kind: :below_min_length, detail: "min #{req.min_length}, got #{len}") if req.min_length && len < req.min_length
          violations << Violation.new(path: req.path, kind: :above_max_length, detail: "max #{req.max_length}, got #{len}") if req.max_length && len > req.max_length
        end

        # Enum.
        if req.enum && !req.enum.include?(value)
          violations << Violation.new(
            path: req.path, kind: :not_in_enum,
            detail: "allowed: #{req.enum.inspect}, got #{value.inspect}"
          )
        end

        # Format.
        if req.format && value.is_a?(String) && !format_match?(value, req.format)
          violations << Violation.new(path: req.path, kind: :format_mismatch, detail: "expected #{req.format}")
        end

        # Pattern.
        if req.pattern && value.is_a?(String)
          begin
            re = Regexp.new(req.pattern)
            unless value.match?(re)
              violations << Violation.new(path: req.path, kind: :pattern_mismatch, detail: "expected /#{req.pattern}/")
            end
          rescue RegexpError
            violations << Violation.new(path: req.path, kind: :invalid_pattern, detail: req.pattern)
          end
        end

        violations
      end

      # Walk a dotted path inside a JSON-shaped Hash. Missing intermediate
      # keys yield nil (absent) rather than an exception.
      def dig(payload, path)
        parts = path.to_s.split(".")
        node = payload
        parts.each do |key|
          break nil unless node.is_a?(Hash)

          node = node[key]
        end
        node
      end

      def type_match?(value, type)
        case type
        when "integer" then value.is_a?(Integer)
        when "number"  then value.is_a?(Numeric)
        when "string"  then value.is_a?(String)
        when "boolean" then value == true || value == false
        when "array"   then value.is_a?(Array)
        when "object"  then value.is_a?(Hash)
        else true
        end
      end

      def ruby_type_name(value)
        case value
        when Integer then "integer"
        when Float   then "number"
        when String  then "string"
        when true, false then "boolean"
        when Array   then "array"
        when Hash    then "object"
        when nil     then "null"
        else value.class.to_s.downcase
        end
      end

      def format_match?(value, format)
        case format
        when "email"   then value.match?(EMAIL_RE)
        when "uri"     then value.match?(URI_RE)
        when "uuid"    then value.match?(UUID_RE)
        when "iso8601" then value.match?(ISO8601_RE)
        else true
        end
      end
    end
  end
end
