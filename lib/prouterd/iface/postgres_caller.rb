require "json"

module Prouterd
  module Iface
    # Caller for `interface postgres`. Invoked by `Runner::CallRunner` when
    # a block references an outbound postgres interface.
    #
    # Reads from `request.type_fields` (orchestrator merged the iface body
    # and the templated per-call fields):
    #   * `dsn`               — required postgres connection string. URL form
    #                           ("postgres://user:pass@host:5432/db") or
    #                           libpq keyword=value form. Templated, so
    #                           `dsn "{{secret.PG_DSN}}"` works.
    #   * `statement-timeout` — applied via `SET LOCAL statement_timeout =`
    #                           after BEGIN. Optional. Milliseconds.
    #   * `query`             — required SQL with $1, $2 placeholders.
    #   * `params`            — comma-separated values bound to $1..$N.
    #                           Quote values that themselves contain
    #                           commas: `params '"Doe, John",42'`.
    #
    # Output JSON shape:
    #   { "rows" => [{...}, ...],
    #     "row_count" => N,
    #     "fields" => ["col1", "col2", ...] }
    #
    # The `pg` gem is required lazily — installs that never use this
    # interface don't pay the dep cost. Missing pg returns
    # error_type:"missing_dependency".
    class PostgresCaller
      def self.pg_available?
        require "pg"
        true
      rescue LoadError
        false
      end

      def run(request)
        started_at = Time.now.utc
        result = perform_run(request)
        finished_at = Time.now.utc
        Runner::ExecutionResult.new(
          exit_code:     result[:exit_code],
          stdout:        result[:stdout].to_s,
          stderr:        result[:stderr].to_s,
          output_json:   result[:output_json],
          artifacts:     [],
          error_type:    result[:error_type],
          error_message: result[:error_message],
          duration_ms:   ((finished_at - started_at) * 1000).to_i,
          started_at:    started_at.iso8601(3),
          finished_at:   finished_at.iso8601(3)
        )
      end

      private

      def perform_run(request)
        unless self.class.pg_available?
          return error("missing_dependency",
                       "interface postgres requires the 'pg' gem (gem install pg)")
        end

        dsn = request.field("dsn").to_s
        return error("invalid_interface", "interface missing dsn") if dsn.empty?

        query = request.field("query").to_s
        return error("invalid_call", "block missing 'query'") if query.empty?

        params = parse_params(request.field("params"))

        statement_timeout_ms = parse_int(request.field("statement-timeout"), nil)

        conn = PG.connect(dsn)
        begin
          conn.exec("BEGIN")
          conn.exec("SET LOCAL statement_timeout = #{statement_timeout_ms.to_i}") if statement_timeout_ms

          result = if params.empty?
                     conn.exec(query)
                   else
                     conn.exec_params(query, params)
                   end

          rows      = result.map { |r| r }
          fields    = result.fields
          row_count = result.cmd_tuples
          conn.exec("COMMIT")

          {
            exit_code:   0,
            output_json: { "rows" => rows, "row_count" => row_count, "fields" => fields },
            stdout:      "",
            stderr:      "",
            error_type:  nil, error_message: nil
          }
        rescue PG::Error => e
          conn.exec("ROLLBACK") rescue nil
          # SQLSTATE 57014 is `query_canceled`, the timeout case.
          err_type = e.respond_to?(:result) && e.result &&
                     e.result.error_field(PG::PG_DIAG_SQLSTATE) == "57014" ? "timeout" : "sql_error"
          { exit_code: nil, output_json: nil, stdout: "", stderr: e.message,
            error_type: err_type, error_message: e.message }
        ensure
          conn.close rescue nil
        end
      rescue StandardError => e
        error("postgres_error", "#{e.class}: #{e.message}")
      end

      # Comma-separated value list, with quote handling so values containing
      # commas don't split. Mirrors the `match ... in` value parser.
      def parse_params(value)
        return [] if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        return value if value.is_a?(Array)

        raw = value.to_s
        out = []
        i = 0
        len = raw.length
        while i < len
          i += 1 while i < len && (raw[i] == " " || raw[i] == "\t" || raw[i] == ",")
          break if i >= len

          if raw[i] == '"'
            j = i + 1
            buf = String.new(encoding: Encoding::UTF_8)
            while j < len && raw[j] != '"'
              if raw[j] == "\\" && j + 1 < len
                buf << raw[j + 1]
                j += 2
              else
                buf << raw[j]
                j += 1
              end
            end
            out << buf
            i = j + 1
          else
            j = i
            j += 1 while j < len && raw[j] != ","
            out << raw[i...j].strip
            i = j
          end
        end
        out
      end

      def parse_int(value, default)
        return default if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        Integer(value.to_s)
      rescue ArgumentError, TypeError
        default
      end

      def error(type, message)
        { exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message }
      end
    end
  end
end
