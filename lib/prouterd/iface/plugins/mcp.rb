require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface mcp <name>` — a JSON-RPC client that talks Model
      # Context Protocol (https://modelcontextprotocol.io) to a
      # subprocess server. The daemon owns the subprocess: spawned at
      # daemon start, restarted on crash with exponential backoff, shut
      # down at daemon stop.
      #
      # Tools advertised by the server (via `tools/list` after the
      # `initialize` handshake) become available to agentic blocks
      # under the namespace `<name>.<tool>`. Per-block opt-in via
      # `mcp <iface>[, <iface>...]`; per-block scoping via
      # `allowed-tools <iface>.<tool>[, ...]`.
      #
      # Trust model. The subprocess runs as the daemon user with the
      # daemon's filesystem and network. THE SERVER CAN READ THE
      # DAEMON'S DB. For untrusted servers, isolate via
      # `server raw "docker run --rm -i ..."` — prouterd does NOT add
      # a sandbox layer.
      #
      # Example:
      #
      #   secret JIRA_TOKEN
      #    source env JIRA_TOKEN
      #   exit
      #
      #   interface mcp atlassian
      #    server npx "@atlassian/mcp-server@1.4.2"
      #    cwd /opt/atp
      #    env JIRA_URL "https://example.atlassian.net"
      #    secret JIRA_TOKEN
      #    timeout-tool-call 30s
      #   exit
      #
      #   block triage
      #    interface llm codex
      #    agentic on
      #    mcp atlassian
      #    allowed-tools atlassian.search_issues, atlassian.get_issue
      #    tool-call-limit 8
      #   exit
      class Mcp < Plugin
        type "mcp"
        direction :outbound

        # `server <kind> "<spec>"` — the only required field.
        # `<kind>` ∈ npx | uvx | bin | raw — see McpClient::ServerCommand
        # for resolution semantics. The spec string is plugin-validated.
        field :server, kind: :mcp_server, required: true,
                       description: "subprocess to spawn: <kind> \"<spec>\" (npx/uvx/bin/raw)"

        # Working directory for the subprocess. Resolved against the
        # daemon's CWD. Optional — defaults to daemon CWD.
        field :cwd, kind: :string,
                    description: "subprocess working directory"

        # Static env vars passed to the subprocess (`env KEY VALUE`,
        # repeats accumulate). NEVER carries secret values directly —
        # use `secret <NAME>` for that, which resolves at spawn time.
        field :env, kind: :env_pair,
                    description: "static env vars: env KEY VALUE; repeats accumulate"

        # `secret <NAME>` lines — each names a `secret <NAME>` declared
        # at the document root. The resolved value is threaded into the
        # subprocess's env under the same KEY. Multiple `secret` lines
        # are allowed and accumulate.
        field :secret, kind: :secret_ref,
                       description: "thread a declared secret as env var to the subprocess"

        # Per-tools/call timeout. Defaults to 60s if unset.
        field :"timeout-tool-call", kind: :duration_ms,
                                    description: "per-tools/call wall-clock timeout"

        caller "Prouterd::Iface::McpClient"

        # Plugin-level validation:
        #   1. Each `secret <NAME>` must reference a declared secret.
        #   2. `server raw "<spec>"` MUST NOT contain `{{...}}` —
        #      template substitution at spawn time would be a shell
        #      injection vector. Static env vars and the named
        #      `secret <NAME>` mechanism are the supported channels
        #      for runtime values.
        def self.validate(iface, document, result)
          (iface.type_fields["secret"] || []).each do |secret_name|
            unless document.secrets.any? { |s| s.name == secret_name }
              result.error(
                "interface mcp '#{iface.name}' references undeclared secret '#{secret_name}'",
                line: iface.line
              )
            end
          end

          server = iface.type_fields["server"]
          if server.is_a?(Hash) && server["kind"] == "raw"
            spec = server["spec"].to_s
            if spec.include?("{{") && spec.include?("}}")
              result.error(
                "interface mcp '#{iface.name}': `server raw` does not template — " \
                "use `env` / `secret` directives to thread runtime values into the subprocess",
                line: iface.line
              )
            end
          end
        end
      end

      Registry.register!(Mcp)
    end
  end
end
