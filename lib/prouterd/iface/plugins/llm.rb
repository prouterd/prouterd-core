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
        field :provider, kind: :enum, enum: %w[anthropic openai], required: true,
                         description: "LLM provider"
        field :model, kind: :string, required: true,
                      description: "model identifier (e.g. claude-haiku-4-5-20251001, gpt-4o-mini)"
        field :"base-url", kind: :string,
                            description: "override the provider's public base URL (proxy / self-hosted)"
        field :auth, kind: :auth_bearer,
                     description: "auth bearer secret <NAME> — API key, sent as the provider's header"

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
          return unless auth

          unless document.secrets.any? { |s| s.name == auth.secret_name }
            result.error(
              "interface '#{iface.name}' references unknown secret '#{auth.secret_name}'",
              line: auth.line
            )
          end
        end
      end

      Registry.register!(Llm)
    end
  end
end
