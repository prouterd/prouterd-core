# frozen_string_literal: true

module Prouterd
  module Runtime
    # Run-scoped data that flows between blocks. Templating in call-fields
    # reads paths directly from the context; on success, the block's output
    # JSON is auto-stored at context[block.name] for downstream blocks.
    #
    # Paths are dot-separated (`event.body`, `lead.scored.score`). All
    # intermediate hops MUST be Hashes for set; for get, missing hops simply
    # yield nil.
    class Context
      def initialize(initial = {})
        @data = deep_dup(initial)
      end

      def to_h
        deep_dup(@data)
      end

      # Return the value at the given dotted path, or nil if any hop is missing
      # or non-Hash on the way down.
      def get(path)
        return @data if path.nil? || path.empty?

        path.to_s.split(".").reduce(@data) do |acc, key|
          if acc.is_a?(Hash)
            acc[key]
          elsif acc.is_a?(Array) && key =~ /\A\d+\z/
            acc[key.to_i]
          else
            break nil
          end
        end
      end

      # Set a dotted path to a value. Auto-creates intermediate Hashes when
      # they are missing or non-Hash (with a TypeError for the latter case to
      # avoid silently shadowing user data).
      def set(path, value)
        raise ArgumentError, "set requires a non-empty path" if path.nil? || path.to_s.empty?

        parts = path.to_s.split(".")
        last = parts.pop
        node = @data
        parts.each do |key|
          if node[key].nil?
            node[key] = {}
          elsif !node[key].is_a?(Hash)
            raise TypeError, "context path '#{path}' collides with a non-Hash value at '#{key}'"
          end
          node = node[key]
        end
        node[last] = value
      end

      def merge_into(path, hash)
        existing = get(path)
        if existing.is_a?(Hash) && hash.is_a?(Hash)
          set(path, existing.merge(hash))
        else
          set(path, hash)
        end
      end

      private

      def deep_dup(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_dup(v) }
        when Array then value.map { |v| deep_dup(v) }
        else            value
        end
      end
    end
  end
end
