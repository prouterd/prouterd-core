# frozen_string_literal: true

module Prouterd
  module Iface
    # Mixin for outbound iface callers. Wraps the caller's per-request
    # body in timing instrumentation and packages the result as a
    # Runner::ExecutionResult — the contract CallRunner expects.
    #
    # Caller writes a private `perform_run(request)` that returns a
    # plain Hash with these keys (all strings/nil):
    #
    #   exit_code     — Integer | nil
    #   output_json   — Hash | Array | nil
    #   stdout        — String
    #   stderr        — String
    #   error_type    — String | nil   (nil means success)
    #   error_message — String | nil
    #   artifacts     — optional Array<ArtifactDescriptor>, defaults to []
    #
    # The mixin's `run(request)` calls `perform_run` between two
    # `Time.now` samples, then assembles the ExecutionResult with
    # duration_ms / started_at / finished_at filled in. Callers don't
    # repeat this boilerplate — and don't accidentally drift on the
    # timestamp format.
    module CallerTiming
      def run(request)
        started_at = Time.now.utc
        result = perform_run(request)
        finished_at = Time.now.utc

        Runner::ExecutionResult.new(
          exit_code:     result[:exit_code],
          stdout:        result[:stdout].to_s,
          stderr:        result[:stderr].to_s,
          output_json:   result[:output_json],
          artifacts:     result[:artifacts] || [],
          error_type:    result[:error_type],
          error_message: result[:error_message],
          duration_ms:   ((finished_at - started_at) * 1000).to_i,
          started_at:    started_at.iso8601(3),
          finished_at:   finished_at.iso8601(3)
        )
      end
    end
  end
end
