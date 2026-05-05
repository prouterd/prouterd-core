module Prouterd
  module Runner
    # Two-stage Docker container shutdown shared between DockerRunner
    # (post-block-execution cleanup), `v1.rb` cancel handler, and the
    # Recovery sweep (orphan kill at boot).
    #
    # SIGTERM first with a configurable grace window so the process
    # flushes logs / output.json / cleans up partial state, then SIGKILL
    # if it didn't exit. Errors swallowed — caller has nothing useful
    # to do with them; the container may already be gone.
    module DockerStop
      DEFAULT_STOP_TIMEOUT = 10

      module_function

      def force_stop(container)
        timeout = (ENV["PROUTERD_CONTAINER_STOP_TIMEOUT"] || DEFAULT_STOP_TIMEOUT).to_i
        container.stop("t" => timeout)
      rescue Docker::Error::DockerError, StandardError
        begin
          container.kill
        rescue Docker::Error::DockerError, StandardError
          # nothing more we can do
        end
      end
    end
  end
end
