require_relative "iface/plugin"
require_relative "iface/registry"

# Caller classes for outbound interfaces. Loaded lazily via autoload so
# `require "prouterd"` doesn't pull in Net::HTTP / future LLM SDKs at boot
# — only the runtime path that actually invokes the caller does.
module Prouterd
  module Iface
    autoload :HttpCaller, File.expand_path("iface/http_caller", __dir__)
    autoload :LlmCaller,  File.expand_path("iface/llm_caller",  __dir__)
  end
end

# Built-in interface plugins. Registry is empty until these load; third-
# party plugins ship their own files and call Registry.register! at load.
require_relative "iface/plugins/webhook"
require_relative "iface/plugins/cron"
require_relative "iface/plugins/manual"
require_relative "iface/plugins/http"
require_relative "iface/plugins/llm"
require_relative "iface/plugins/docker"
require_relative "iface/plugins/shell"
