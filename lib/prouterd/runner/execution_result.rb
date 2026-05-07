module Prouterd
  module Runner
    # Outcome of a single block execution. Returned by every Runner adapter.
    #
    # error_type values:
    #   nil              — success
    #   "non_zero_exit"  — process exited with a non-zero code
    #   "missing_output" — /prouter/output.json was not produced
    #   "invalid_output" — output.json is not parseable JSON
    #   "timeout"        — execution exceeded the block's timeout
    #   "docker_error"   — runner-internal failure (image pull, daemon, etc.)
    ExecutionResult = Struct.new(
      :exit_code,
      :stdout,
      :stderr,
      :output_json,
      :artifacts,
      :error_type,
      :error_message,
      :duration_ms,
      :started_at,
      :finished_at,
      keyword_init: true
    ) do
      def success?
        error_type.nil? && exit_code == 0
      end

      def to_step_status
        if success?
          "success"
        elsif error_type == "timeout"
          "timeout"
        else
          "failed"
        end
      end

      # Reshape a successful result into a logical failure. Used when a
      # retry-when predicate matched on the output but max attempts were
      # already consumed — the run can't proceed but the attempt itself
      # had exit 0, so we reroute it through the failure path with a
      # synthetic error_type the operator can grep for.
      def dup_as_failure(error_type:, error_message:)
        ExecutionResult.new(
          exit_code: exit_code,
          stdout: stdout, stderr: stderr,
          output_json: output_json,
          artifacts: artifacts,
          error_type: error_type,
          error_message: error_message,
          duration_ms: duration_ms,
          started_at: started_at,
          finished_at: finished_at
        )
      end
    end

    # Spec'd shape of an artifact that the runner discovered in /prouter/artifacts/.
    # `name` is the relative path inside the artifacts directory; `host_path` is
    # the absolute path on the host where the file currently lives (the runner's
    # work dir). The orchestrator hands these to ArtifactStore for archival.
    ArtifactDescriptor = Struct.new(:name, :host_path, :size_bytes, :content_type, :checksum, keyword_init: true)
  end
end
