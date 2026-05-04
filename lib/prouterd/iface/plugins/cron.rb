require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface cron <name>` — fires on schedule. The runtime Scheduler
      # ticks once per second, picks up cron interfaces whose schedule has
      # come due, and enqueues a run for whichever process is wired via
      # `route interface <name> process <name>`.
      class Cron < Plugin
        type "cron"
        direction :inbound

        field :schedule, kind: :string, required: true,
                         description: "cron expression (parsed by fugit)"
        field :timezone, kind: :string,
                         description: "IANA timezone (e.g. Europe/Berlin); defaults to system TZ"
      end

      Registry.register!(Cron)
    end
  end
end
