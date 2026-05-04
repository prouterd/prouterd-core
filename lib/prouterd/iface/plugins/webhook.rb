require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface webhook <name>` — HTTP listener. The daemon's webhook
      # handler resolves a request to this interface by matching the URL
      # path, then enqueues a run for whichever process is wired via
      # `route interface <name> process <name>`.
      class Webhook < Plugin
        type "webhook"
        direction :inbound

        # Pre-defined HTTP methods accepted by `method` field. Lowercase
        # input is uppercased at parse time.
        HTTP_METHODS = %w[GET POST PUT DELETE PATCH].freeze

        field :path,   kind: :path,         required: true,
                       description: "URL path the listener responds on (must start with /)"
        field :method, kind: :http_method,  default: "POST",
                       description: "HTTP method"
        field :auth,   kind: :auth_bearer,
                       description: "auth bearer secret <NAME>"

        # The renderer consults `field.kind` to render. Auth and path are
        # rendered specially; method only emits when set non-default.
        def self.validate(iface, document, result)
          if iface.type_fields["auth"]
            secret_name = iface.type_fields["auth"].secret_name
            unless document.secrets.any? { |s| s.name == secret_name }
              result.error(
                "interface '#{iface.name}' references unknown secret '#{secret_name}'",
                line: iface.type_fields["auth"].line
              )
            end
          end
        end
      end

      Registry.register!(Webhook)
    end
  end
end
