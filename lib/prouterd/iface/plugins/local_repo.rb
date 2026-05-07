require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface local_repo <name>` — read-only, whitelisted, sandboxed
      # access to local git checkouts. Lets blocks gather commits, read
      # tracked files, and grep for patterns under a controlled set of
      # directories — without granting arbitrary shell access.
      #
      # Example:
      #
      #   interface local_repo workspace
      #    root /opt/atp/checkouts
      #    whitelist vosio/app, vosio/api-gateway
      #    default-branch develop
      #    sandbox read-only
      #    max-file-size 500KB
      #   exit
      #
      # Checkout freshness is the operator's responsibility — keep an
      # external cron job pulling under `root`. The daemon does not
      # fetch / pull / write.
      #
      #   block fetch_repo
      #    interface local_repo workspace
      #    call grep
      #    repo vosio/app
      #    pattern "TODO\\(release-blocker\\)"
      #   exit
      #
      # Output JSON shape (per call):
      #   gather  -> { "commits": [{sha,author,subject,timestamp,files:[]}, ...] }
      #   read    -> { "path": "<repo-relative>", "content": "<text>", "size": N }
      #   grep    -> { "matches": [{file, line, text}, ...] }
      class LocalRepo < Plugin
        type "local_repo"
        direction :outbound

        SANDBOX_VALUES = %w[read-only].freeze
        CALL_KINDS     = %w[gather read grep].freeze

        field :root, kind: :string, required: true,
                     description: "absolute base directory holding the whitelisted repos"
        field :whitelist, kind: :command, required: true,
                          description: "comma-separated repo names; each must resolve to an existing directory under root"
        field :"default-branch", kind: :string, default: "main",
                                  description: "branch used when a call doesn't specify one"
        field :sandbox, kind: :enum, enum: SANDBOX_VALUES, default: "read-only",
                        description: "sandbox mode (currently only read-only)"
        field :"max-file-size", kind: :string, default: "500KB",
                                 description: "size cap for `read` calls; suffix-aware (KB/MB)"

        call_field :call, kind: :enum, enum: CALL_KINDS, required: true,
                          description: "which subcommand to run"
        call_field :repo, kind: :string, required: true,
                          description: "one of the whitelisted repo names"
        call_field :path, kind: :string,
                          description: "repo-relative file or directory path (read / grep within subtree)"
        call_field :pattern, kind: :string,
                             description: "regex pattern for `grep`"
        call_field :branch, kind: :string,
                            description: "ref to operate against (overrides default-branch)"
        call_field :since, kind: :string,
                           description: "git --since for `gather` (e.g. \"24 hours ago\")"
        call_field :until, kind: :string,
                           description: "git --until for `gather`"
        call_field :"max-results", kind: :string, default: "50",
                                    description: "cap on rows for `gather` / `grep`"

        caller "Prouterd::Iface::LocalRepoCaller"

        def self.validate(iface, _document, result)
          root = iface.type_fields["root"]
          if root && !root.start_with?("/")
            result.error(
              "interface '#{iface.name}': root must be an absolute path",
              line: iface.line
            )
          end
          whitelist = iface.type_fields["whitelist"]
          if whitelist && whitelist.split(",").map(&:strip).reject(&:empty?).empty?
            result.error(
              "interface '#{iface.name}': whitelist must list at least one repo",
              line: iface.line
            )
          end
        end
      end

      Registry.register!(LocalRepo)
    end
  end
end
