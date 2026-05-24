# frozen_string_literal: true

module Prouterd
  module Shell
    # Aligned-column table rendering for `show *` commands. Removes the
    # per-table duplication of a format string between the header line
    # and the row loop — a single column spec drives both.
    #
    # Usage:
    #
    #   Table.render(out,
    #     { "NAME" => 30, "STATE" => 10, "DETAIL" => nil },
    #     interfaces.map { |i| [i.name, i.state, i.detail] }
    #   )
    #
    # Column widths are left-padded `%-Ns` columns; a `nil` width (only
    # meaningful for the last column) leaves the value unconstrained
    # via plain `%s`. Values pass through `.to_s` so callers can mix
    # integers / nils freely; nil renders as empty.
    module Table
      module_function

      def render(out, columns, rows)
        fmt = columns.values.map { |w| w ? "%-#{w}s" : "%s" }.join(" ")
        out.puts(fmt % columns.keys)
        rows.each do |row|
          out.puts(fmt % row.map(&:to_s))
        end
      end
    end
  end
end
