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
        # Subprocess env controls. The default (none declared) keeps
        # back-compat: the spawn inherits the daemon's full env. Declare
        # ANY of these and the driver flips to `unsetenv_others: true`,
        # assembling the subprocess env strictly from:
        #
        #   1. HOME (the iface's `home` field, else the daemon's HOME)
        #   2. each `env KEY VALUE` directive
        #   3. each `env-forward KEY` directive — passes through if
        #      KEY is set in the daemon's env, omitted otherwise
        #   4. each `secret <NAME>` directive — resolves through the
        #      declared `secret <NAME> / source env <X> / exit` and
        #      exposes the value under env key <NAME>
        #
        # Strict mode is the opt-in security model for subprocess LLMs.
        # Without it, a prompt-injection in a customer-supplied payload
        # could exfiltrate any env var the daemon was started with.
        field :env, kind: :env_pair,
                    description: "static env var (env KEY VALUE); repeats accumulate"
        field :"env-forward", kind: :env_forward,
                               description: "pass through a daemon env var (env-forward KEY) if present"
        field :secret, kind: :secret_ref,
                       description: "thread a declared secret into the subprocess env (secret <NAME>)"

        # Per-call args — supplied by a block referencing this interface.
        call_field :prompt, kind: :command, required: true,
                            description: "user prompt; templated per-run via {{...}}"
        call_field :system, kind: :command,
                            description: "optional system prompt; templated"
        call_field :"max-tokens", kind: :string, default: "1024",
                                   description: "max tokens to generate (string for templating)"
        call_field :temperature, kind: :string,
                                  description: "sampling temperature (string for templating)"
        # Subprocess-provider knobs. `cwd` rebinds the spawn's working
        # directory so an agent CLI (codex_cli / claude_cli) sees a
        # project-rooted view of the filesystem — without this both CLIs
        # default to the daemon's cwd, which is rarely the repo the
        # agent is meant to investigate. `reasoning-effort` is codex's
        # `-c model_reasoning_effort=<level>` config override; production
        # runs typically want `low`/`medium` rather than the CLI's
        # `xhigh` default. Both are silently ignored for HTTP providers.
        call_field :cwd, kind: :string,
                          description: "working directory for the spawned subprocess (codex_cli/claude_cli)"
        call_field :"reasoning-effort", kind: :enum, enum: %w[low medium high xhigh],
                                         description: "codex_cli reasoning effort (-c model_reasoning_effort=<level>)"
        # `stream on` turns a subprocess LLM block into a live-tail
        # source: the driver invokes the CLI in JSONL streaming mode
        # (codex_cli already uses --json; claude_cli flips from
        # --output-format json to --output-format stream-json) and
        # writes each parsed line as a row in run_logs as it arrives,
        # so `prouter logs <run_uid> --follow` shows progress for a
        # 10-minute agent run without bypassing the daemon. The final
        # aggregated output_json (text, usage, stop_reason) is unchanged
        # — downstream blocks see the same shape regardless of stream.
        call_field :stream, kind: :enum, enum: %w[on off], default: "off",
                            description: "stream JSONL events to run_logs as they arrive (codex_cli / claude_cli)"

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

          # env / env-forward / secret only thread into the spawn for
          # subprocess providers — HTTP callers (anthropic/openai) reach
          # the upstream over Net::HTTP and don't need a controlled env.
          if !subprocess_provider &&
             (iface.type_fields["env"] || iface.type_fields["env-forward"] || iface.type_fields["secret"])
            result.error(
              "interface '#{iface.name}': `env` / `env-forward` / `secret` only apply to codex_cli / claude_cli providers",
              line: iface.line
            )
          end

          # Each declared `secret <NAME>` must reference a known secret.
          Array(iface.type_fields["secret"]).each do |secret_name|
            unless document.secrets.any? { |s| s.name == secret_name }
              result.error(
                "interface '#{iface.name}' references undeclared secret '#{secret_name}'",
                line: iface.line
              )
            end
          end
        end
      end

      Registry.register!(Llm)
    end
  end
end
