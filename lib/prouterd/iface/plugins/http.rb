require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface http <name>` — declares an outbound HTTP endpoint. A
      # `block` calls into it with `type call` and per-call fields:
      #
      #   interface jira
      #    type http
      #    base-url https://acme.atlassian.net/rest/api/3
      #    auth bearer secret JIRA_TOKEN
      #   exit
      #
      #   block fetch_jira
      #    type call
      #     use jira
      #     method GET
      #     path "/issue/{{event.issue.key}}"
      #    exit
      #    input event
      #    output ticket
      #   exit
      #
      # The interface centralises base-url + credentials so dozens of
      # blocks call the same upstream without duplicating config.
      class Http < Plugin
        type "http"
        direction :outbound

        # Interface-level config — declared once, shared across all blocks
        # using this interface.
        field :"base-url", kind: :string, required: true,
                            description: "scheme + host + optional path prefix; per-call paths append to it"
        field :auth, kind: :auth_bearer,
                     description: "auth bearer secret <NAME> — adds Authorization: Bearer to every call"

        # Per-call args — supplied by a block that references this interface.
        call_field :method, kind: :http_method, default: "GET",
                            description: "HTTP method (uppercased)"
        call_field :path, kind: :string,
                          description: "appended to base-url; templated per-run via {{ctx.path}}"
        call_field :query, kind: :string,
                           description: "raw query string, e.g. 'k=v&k2=v2'; templated"
        call_field :"body-json", kind: :command,
                                  description: "request body, sent with Content-Type: application/json; templated"

        caller "Prouterd::Iface::HttpCaller"

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

      Registry.register!(Http)
    end
  end
end
