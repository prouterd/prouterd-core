module Prouterd
  module Runtime
    # Strips secret values from arbitrary text before it lands in run_logs,
    # error_summary, or any other persisted/displayed surface.
    #
    # Secret VALUES must never appear in show commands or logs. The
    # orchestrator builds a Redactor per run from the resolved
    # values of every secret declared in the document — even secrets the
    # block in question doesn't reference, since a misbehaving block could
    # still leak a peer-block's secret if the env var name matches.
    class Redactor
      MASK = "********".freeze

      def self.from_document(document, secret_resolver)
        values = document.secrets.map { |s| secret_resolver.resolve(s) }
        new(values)
      end

      def initialize(secret_values)
        # Reject nil/empty values; longer-first so a long token isn't
        # partially masked when one is a prefix of another.
        @values = (secret_values || [])
                   .compact
                   .reject(&:empty?)
                   .uniq
                   .sort_by { |v| -v.length }
      end

      def empty?
        @values.empty?
      end

      def redact(text)
        return text if text.nil? || text.empty? || @values.empty?

        out = text.dup
        @values.each do |value|
          out.gsub!(value, MASK)
        end
        out
      end

      # Phase 35c: recursively scrub secret values out of structured
      # output. Used by the orchestrator before storing a block's
      # `output_json` into the shared Context (otherwise a block that
      # echoes `{{secret.X}}` back into its output would leak the value
      # downstream via `{{block.field}}` templating + /prouter/input.json).
      # Walks Hash and Array containers; redacts every leaf String;
      # everything else (numbers, booleans, nil) passes through.
      def redact_json(value)
        case value
        when nil then nil
        when String then redact(value)
        when Hash then value.transform_values { |v| redact_json(v) }
        when Array then value.map { |v| redact_json(v) }
        else value
        end
      end
    end
  end
end
