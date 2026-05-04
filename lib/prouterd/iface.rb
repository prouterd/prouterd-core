require_relative "iface/plugin"
require_relative "iface/registry"

# Built-in interface plugins. Registry is empty until these load; third-
# party plugins (e.g. an HTTP client interface, an LLM interface) require
# their own file the same way and call Registry.register! at the bottom.
require_relative "iface/plugins/webhook"
require_relative "iface/plugins/cron"
require_relative "iface/plugins/manual"
