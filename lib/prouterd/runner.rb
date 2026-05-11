# frozen_string_literal: true

require_relative "runner/execution_result"
require_relative "runner/run_request"
require_relative "runner/stub_runner"
require_relative "runner/shell_runner"
require_relative "runner/call_runner"

# DockerRunner pulls in docker-api which we don't want at parse-time;
# autoload only the runtime path that actually invokes a docker caller.
module Prouterd
  module Runner
    autoload :DockerRunner, File.expand_path("runner/docker_runner", __dir__)
    autoload :DockerStop,   File.expand_path("runner/docker_stop",   __dir__)
  end
end
