require_relative "runner/execution_result"
require_relative "runner/run_request"
require_relative "runner/stub_runner"
# DockerRunner is loaded lazily so requiring `prouterd` doesn't require docker-api
# at boot — only the orchestrator's wiring path pulls it in.

module Prouterd
  module Runner
    autoload :DockerRunner, File.expand_path("runner/docker_runner", __dir__)
  end
end
