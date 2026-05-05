require "json"

module Prouterd
  module Util
    # Mustache-style {{path.to.value}} substitution against a context hash.
    #
    # Deliberately tiny: no conditionals, no loops, no filters, no eval.
    # The DSL must stay declarative — adding a Turing-complete templater
    # turns `.prc` into a programming language.
    #
    # Path rules:
    #   - {{x}}       — context["x"]
    #   - {{x.y.z}}   — context["x"]["y"]["z"] when intermediate hops are Hashes
    #   - {{ x.y }}   — whitespace inside braces is allowed and trimmed
    #   - missing path → "" (empty string), so a template never blows up
    #
    # Value formatting:
    #   - String       — emitted verbatim
    #   - Numeric/bool — `to_s`
    #   - Hash/Array   — `JSON.dump(...)` so embedding {{event}} in a JSON
    #                    body produces a parseable payload
    #   - nil/missing  — ""
    #
    # The `context` argument is either a Hash with string keys, or an
    # object responding to `#get(dotted_path)` — `Runtime::Context` qualifies.
    module Templater
      module_function

      VAR_RE = /\{\{\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\}\}/.freeze

      def render(template, context)
        return template unless template.is_a?(String)
        return template unless template.include?("{{")

        template.gsub(VAR_RE) do
          format_value(resolve(context, Regexp.last_match(1)))
        end
      end

      def resolve(context, path)
        return context.get(path) if context.respond_to?(:get)

        path.split(".").reduce(context) do |acc, key|
          if acc.is_a?(Hash)
            acc[key] || acc[key.to_sym]
          elsif acc.is_a?(Array) && key =~ /\A\d+\z/
            acc[key.to_i]
          else
            break nil
          end
        end
      end

      def format_value(value)
        case value
        when nil                          then ""
        when String                       then value
        when Integer, Float, true, false  then value.to_s
        else                                   JSON.dump(value)
        end
      end
    end
  end
end
