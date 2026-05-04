module Prouterd
  module Runner
    # Single dispatch runner. Replaces the per-type-runner registry: instead
    # of choosing between DockerRunner / ShellRunner / etc. by block type,
    # the orchestrator hands every block to CallRunner. CallRunner resolves
    # the block's `interface <type> <name>` directive to the declared
    # AST::Interface, looks up the interface plugin's `caller_class`, and
    # delegates the actual run.
    #
    # Caller classes (DockerRunner, ShellRunner, HttpCaller, ...) keep the
    # same `run(request) -> ExecutionResult` contract — only the dispatch
    # path changes.
    class CallRunner
      def initialize(in_flight: nil, warm_pool: nil)
        @in_flight = in_flight
        @warm_pool = warm_pool
        @cache = {}
      end

      def run(request)
        plugin = Prouterd::Iface::Registry.lookup(request.execution_type)
        unless plugin
          return failure("invalid_interface_type",
                         "no interface plugin registered for type '#{request.execution_type}'")
        end

        caller_class = plugin.caller_class
        instance = (@cache[caller_class] ||= build_caller(caller_class))
        instance.run(request)
      rescue StandardError => e
        failure("dispatch_error", "#{e.class}: #{e.message}")
      end

      private

      def build_caller(klass)
        # Each caller takes whatever subset of {in_flight:, warm_pool:} it
        # actually accepts — same contract as Runner::Plugin.build_runner
        # used to do for the old block-type plugins.
        params = klass.instance_method(:initialize).parameters
                      .select { |type, _| %i[key keyreq].include?(type) }
                      .map { |_, name| name }
        kwargs = {}
        kwargs[:in_flight] = @in_flight if params.include?(:in_flight) && @in_flight
        kwargs[:warm_pool] = @warm_pool if params.include?(:warm_pool) && @warm_pool
        klass.new(**kwargs)
      end

      def failure(error_type, error_message)
        ExecutionResult.new(
          exit_code: nil, stdout: "", stderr: "",
          output_json: nil, artifacts: [],
          error_type: error_type, error_message: error_message,
          duration_ms: 0, started_at: nil, finished_at: nil
        )
      end
    end
  end
end
