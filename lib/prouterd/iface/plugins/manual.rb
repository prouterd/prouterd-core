require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface manual <name>` — operator-driven entry point. Triggered
      # via `prouter trigger process <process>` or the `/v1/processes/:name/trigger`
      # admin API. Carries no body fields beyond `shutdown`/`no shutdown`.
      class Manual < Plugin
        type "manual"
        direction :inbound

        # No fields. Operators just declare the interface so it can be
        # the source of a `route interface ... process ...`.
      end

      Registry.register!(Manual)
    end
  end
end
