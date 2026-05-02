require_relative "runner/execution_result"
require_relative "runner/run_request"
require_relative "runner/stub_runner"
require_relative "runner/shell_runner"
require_relative "runner/plugin"
require_relative "runner/registry"

# DockerRunner is loaded lazily so requiring `prouterd` doesn't require docker-api
# at boot — only the orchestrator's wiring path pulls it in.

module Prouterd
  module Runner
    autoload :DockerRunner, File.expand_path("runner/docker_runner", __dir__)
  end
end

# Built-in plugins. Registry is empty until these load; third-party
# plugins (e.g. KubernetesPlugin in a separate gem) require their own
# file the same way and call Registry.register! at the bottom.
require_relative "runner/plugins/shell"
require_relative "runner/plugins/docker"
