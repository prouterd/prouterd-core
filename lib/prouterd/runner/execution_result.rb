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
    end

    # Spec'd shape of an artifact that the runner discovered in /prouter/artifacts/.
    # `name` is the relative path inside the artifacts directory; `host_path` is
    # the absolute path on the host where the file currently lives (the runner's
    # work dir). The orchestrator hands these to ArtifactStore for archival.
    ArtifactDescriptor = Struct.new(:name, :host_path, :size_bytes, :content_type, :checksum, keyword_init: true)
  end
end
