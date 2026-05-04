require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface postgres <name>` — declares an outbound PostgreSQL
      # endpoint. Blocks issue per-call SQL via `query "..."` plus optional
      # `params`. The interface centralises the DSN + global statement
      # timeout so dozens of blocks talk to the same database without
      # duplicating connection config.
      #
      #   secret PG_DSN
      #    source env PG_DSN
      #   exit
      #
      #   interface postgres warehouse
      #    dsn "{{secret.PG_DSN}}"
      #    statement-timeout 5s
      #   exit
      #
      #   block lookup
      #    interface postgres warehouse
      #    query "SELECT id, status FROM tickets WHERE key = $1"
      #    params "{{event.issue.key}}"
      #   exit
      #
      # The `pg` gem is required lazily by the caller — installations that
      # never use `interface postgres` don't pay the dependency cost.
      class Postgres < Plugin
        type "postgres"
        direction :outbound

        # Interface-level config.
        field :dsn, kind: :string, required: true,
                    description: "postgres connection string (URL or libpq keyword=value form)"
        field :"statement-timeout", kind: :string,
                                     description: "server-side timeout, ms (string for templating)"

        # Per-call args.
        call_field :query, kind: :command, required: true,
                            description: "SQL with $1, $2 placeholders; templated"
        call_field :params, kind: :string,
                             description: "comma-separated values bound to $1..$N; templated"

        caller "Prouterd::Iface::PostgresCaller"
      end

      Registry.register!(Postgres)
    end
  end
end
