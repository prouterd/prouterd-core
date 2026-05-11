require_relative "iface/plugin"
require_relative "iface/registry"

# Caller classes for outbound interfaces. Loaded lazily via autoload so
# `require "prouterd"` doesn't pull in Net::HTTP / future LLM SDKs at boot
# — only the runtime path that actually invokes the caller does.
module Prouterd
  module Iface
    autoload :HttpClient,     File.expand_path("iface/http_client",     __dir__)
    autoload :CallerTiming,   File.expand_path("iface/caller_timing",   __dir__)
    autoload :HttpCaller,     File.expand_path("iface/http_caller",     __dir__)
    autoload :LlmCaller,      File.expand_path("iface/llm_caller",      __dir__)
    autoload :LlmSubprocess,  File.expand_path("iface/llm_subprocess",  __dir__)
    autoload :LlmAgentic,     File.expand_path("iface/llm_agentic",     __dir__)
    autoload :PostgresCaller, File.expand_path("iface/postgres_caller", __dir__)
    autoload :LocalRepoCaller, File.expand_path("iface/local_repo_caller", __dir__)
    autoload :LocalRepoStatus, File.expand_path("iface/local_repo_status", __dir__)
    autoload :McpToolRef,     File.expand_path("iface/mcp_tool_ref",     __dir__)
    module Mcp
      autoload :ServerCommand, File.expand_path("iface/mcp/server_command", __dir__)
      autoload :Session,       File.expand_path("iface/mcp/session",        __dir__)
      autoload :Pool,          File.expand_path("iface/mcp/pool",           __dir__)
    end
  end
end

# Built-in interface plugins. Registry is empty until these load; third-
# party plugins ship their own files and call Registry.register! at load.
require_relative "iface/plugins/webhook"
require_relative "iface/plugins/cron"
require_relative "iface/plugins/manual"
require_relative "iface/plugins/http"
require_relative "iface/plugins/llm"
require_relative "iface/plugins/postgres"
require_relative "iface/plugins/docker"
require_relative "iface/plugins/shell"
require_relative "iface/plugins/local_repo"
require_relative "iface/plugins/mcp"
