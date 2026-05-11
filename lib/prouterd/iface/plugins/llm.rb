# frozen_string_literal: true

require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface llm <name>` — declares an outbound LLM endpoint.
      # Provider-agnostic at the DSL level; the caller dispatches to the
      # right provider's HTTP API based on the `provider` field.
      #
      # Example:
      #
      #   secret CLAUDE_KEY
      #    source env CLAUDE_KEY
      #   exit
      #
      #   interface llm claude
      #    provider anthropic
      #    model claude-haiku-4-5-20251001
      #    auth bearer secret CLAUDE_KEY
      #   exit
      #
      #   block summarize
      #    interface llm claude
      #    system "You summarize tickets in one sentence."
      #    prompt "{{event.body}}"
      #    max-tokens 256
      #   exit
      #
      # The block's output JSON contains: text, model, usage, stop_reason,
      # raw. Downstream blocks reference `{{summarize.text}}`.
      class Llm < Plugin
        type "llm"
        direction :outbound

        # Interface-level config — declared once per upstream account.
        field :provider, kind: :enum, enum: %w[anthropic openai codex_cli claude_cli], required: true,
                         description: "LLM provider"
        field :model, kind: :string, required: true,
                      description: "model identifier (e.g. claude-haiku-4-5-20251001, gpt-4o-mini)"
        field :"base-url", kind: :string,
                            description: "override the provider's public base URL (proxy / self-hosted)"
        field :auth, kind: :auth_bearer,
                     description: "auth bearer secret <NAME> — API key (HTTP providers only)"
        field :binary, kind: :string,
                       description: "absolute path to the CLI binary (codex_cli/claude_cli only); defaults to PROUTERD_<PROVIDER>_BIN env or `codex` / `claude` on PATH"
        field :home, kind: :string,
                     description: "HOME for the subprocess (codex_cli/claude_cli) — directory holding subscription state"
        field :sandbox, kind: :string,
                        description: "sandbox mode passed verbatim via `-s <mode>` (codex_cli/claude_cli)"

        # Per-call args — supplied by a block referencing this interface.
        call_field :prompt, kind: :command, required: true,
                            description: "user prompt; templated per-run via {{...}}"
        call_field :system, kind: :command,
                            description: "optional system prompt; templated"
        call_field :"max-tokens", kind: :string, default: "1024",
                                   description: "max tokens to generate (string for templating)"
        call_field :temperature, kind: :string,
                                  description: "sampling temperature (string for templating)"

        caller "Prouterd::Iface::LlmCaller"

        def self.validate(iface, document, result)
          auth = iface.type_fields["auth"]
          if auth
            unless document.secrets.any? { |s| s.name == auth.secret_name }
              result.error(
                "interface '#{iface.name}' references unknown secret '#{auth.secret_name}'",
                line: auth.line
              )
            end
          end

          provider = iface.type_fields["provider"]
          subprocess_provider = %w[codex_cli claude_cli].include?(provider)
          if subprocess_provider && auth
            result.error(
              "interface '#{iface.name}': provider '#{provider}' uses a CLI binary and does not accept `auth bearer secret` " \
              "(authentication lives in the CLI's own subscription state)",
              line: iface.line
            )
          end
          if !subprocess_provider && (iface.type_fields["binary"] || iface.type_fields["home"] || iface.type_fields["sandbox"])
            result.error(
              "interface '#{iface.name}': `binary` / `home` / `sandbox` are only valid for codex_cli / claude_cli providers",
              line: iface.line
            )
          end
        end
      end

      Registry.register!(Llm)
    end
  end
end
