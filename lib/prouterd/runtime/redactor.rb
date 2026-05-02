module Prouterd
  module Runtime
    # Strips secret values from arbitrary text before it lands in run_logs,
    # error_summary, or any other persisted/displayed surface.
    #
    # Spec §23.1/§23.2: secret VALUES must never appear in show commands or
    # logs. The orchestrator builds a Redactor per run from the resolved
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
    end
  end
end
