require "json"

module Prouterd
  module Iface
    # Caller for `interface postgres`. Invoked by `Runner::CallRunner` when
    # a block references an outbound postgres interface.
    #
    # Reads from the resolved AST::Interface:
    #   * dsn — postgres connection string. Either a URL
    #     ("postgres://user:pass@host:5432/db?sslmode=require") or a
    #     libpq keyword=value form. Templated against secrets/env at
    #     parse time is the operator's responsibility — at call time the
    #     value is taken verbatim.
    #   * statement-timeout — server-side statement timeout, applied via
    #     `SET LOCAL statement_timeout = ...` after BEGIN.
    #
    # Reads from per-call type_fields (already templated):
    #   * query  — required SQL, may contain numbered $1, $2, ... placeholders
    #   * params — optional, comma-separated list of values bound to $1..$N
    #
    # Output JSON shape (provider-agnostic):
    #   { "rows" => [{...}, ...],
    #     "row_count" => N,
    #     "fields" => ["col1", "col2", ...] }
    #
    # The pg gem is required lazily — installations that never use
    # `interface postgres` don't pay the dependency cost. If the gem is
    # missing at first call, the caller returns a clean error result.
    class PostgresCaller
      CallerResult = Struct.new(
        :exit_code, :output_json, :stdout, :stderr,
        :error_type, :error_message,
        keyword_init: true
      )

      def self.pg_available?
        require "pg"
        true
      rescue LoadError
        false
      end

      def initialize(secret_resolver: nil)
        @secret_resolver = secret_resolver
      end

      def call(iface:, call_fields:, secrets: {}, timeout_ms: nil)
        unless self.class.pg_available?
          return error("missing_dependency",
                       "interface postgres requires the 'pg' gem (gem install pg)")
        end

        dsn = iface.type_fields["dsn"].to_s
        return error("invalid_interface", "interface '#{iface.name}' missing dsn") if dsn.empty?

        query = call_fields["query"].to_s
        return error("invalid_call", "block missing 'query'") if query.empty?

        params = parse_params(call_fields["params"])

        statement_timeout_ms = parse_int(iface.type_fields["statement-timeout"], nil)

        conn = PG.connect(dsn)
        begin
          conn.exec("BEGIN")
          conn.exec("SET LOCAL statement_timeout = #{statement_timeout_ms.to_i}") if statement_timeout_ms

          result = if params.empty?
                     conn.exec(query)
                   else
                     conn.exec_params(query, params)
                   end

          rows   = result.map { |r| r }
          fields = result.fields
          row_count = result.cmd_tuples
          conn.exec("COMMIT")

          CallerResult.new(
            exit_code: 0,
            output_json: { "rows" => rows, "row_count" => row_count, "fields" => fields },
            stdout: "",
            stderr: "",
            error_type: nil,
            error_message: nil
          )
        rescue PG::Error => e
          conn.exec("ROLLBACK") rescue nil
          # SQLSTATE 57014 is `query_canceled`, the timeout case.
          err_type = e.respond_to?(:result) && e.result &&
                     e.result.error_field(PG::PG_DIAG_SQLSTATE) == "57014" ? "timeout" : "sql_error"
          CallerResult.new(
            exit_code: nil, output_json: nil, stdout: "", stderr: e.message,
            error_type: err_type, error_message: e.message
          )
        ensure
          conn.close rescue nil
        end
      rescue StandardError => e
        error("postgres_error", "#{e.class}: #{e.message}")
      end

      private

      def parse_params(value)
        return [] if value.nil? || value.empty?
        return value if value.is_a?(Array)

        # Comma-separated; whitespace between values is trimmed. Templating
        # has already happened upstream, so {{...}} expansions are baked in.
        value.to_s.split(",").map(&:strip)
      end

      def parse_int(value, default)
        return default if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        Integer(value.to_s)
      rescue ArgumentError, TypeError
        default
      end

      def error(type, message)
        CallerResult.new(
          exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message
        )
      end
    end
  end
end
