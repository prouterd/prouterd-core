# frozen_string_literal: true

module Prouterd
  module Util
    # Parses router-style duration strings into milliseconds.
    #
    # Supported units: ms, s, m, h. Examples: "120s", "2m", "10m", "500ms", "1h".
    # Compound forms ("1m30s") are not supported by design — keeps the DSL minimal.
    module DurationParser
      module_function

      PATTERN = /\A(\d+)(ms|s|m|h)\z/.freeze

      UNITS_MS = {
        "ms" => 1,
        "s"  => 1_000,
        "m"  => 60_000,
        "h"  => 3_600_000
      }.freeze

      def parse(input)
        match = PATTERN.match(input.to_s)
        raise ArgumentError, "invalid duration: #{input.inspect} (expected e.g. 120s, 2m, 500ms)" unless match

        match[1].to_i * UNITS_MS.fetch(match[2])
      end

      # Renders a milliseconds value back into a canonical router-style string.
      # Picks the largest unit that yields an integer value.
      def render(ms)
        raise ArgumentError, "duration must be non-negative integer" unless ms.is_a?(Integer) && ms >= 0

        return "0s" if ms.zero?

        # The "ms" case at the end of the loop always matches because
        # every integer divides by 1; the loop is guaranteed to return.
        %w[h m s ms].each do |unit|
          divisor = UNITS_MS.fetch(unit)
          return "#{ms / divisor}#{unit}" if (ms % divisor).zero?
        end
      end
    end
  end
end
