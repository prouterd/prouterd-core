module Prouterd
  module Storage
    RUN_STATUSES = %w[queued running success failed canceled paused].freeze
    STEP_STATUSES = %w[pending queued running success failed retrying skipped canceled timeout paused].freeze

    Run = Struct.new(
      :id,
      :uid,
      :process_name,
      :process_config_commit_id,
      :interface_name,
      :status,
      :input_event_json,
      :context_json,
      :error_summary,
      :started_at,
      :finished_at,
      :created_at,
      :parent_run_id,
      :replay_of_run_id,
      :replay_of_uid,
      :thread_id,
      :tokens_in,
      :tokens_out,
      :cost_usd,
      keyword_init: true
    ) do
      def success?; status == "success"; end
      def failed?;  status == "failed"; end
      def running?; status == "running"; end
      def terminal?; %w[success failed canceled].include?(status); end

      def duration_ms
        return nil unless started_at && finished_at

        ((Time.parse(finished_at) - Time.parse(started_at)) * 1000).to_i
      end
    end

    Step = Struct.new(
      :id,
      :run_id,
      :block_name,
      :status,
      :attempt,
      :image,
      :input_json,
      :output_json,
      :exit_code,
      :error_type,
      :error_message,
      :started_at,
      :finished_at,
      :duration_ms,
      :created_at,
      keyword_init: true
    ) do
      def success?; status == "success"; end
      def failed?;  status == "failed" || status == "timeout"; end
    end

    LogEntry = Struct.new(
      :id, :run_id, :step_id, :stream, :content, :created_at,
      keyword_init: true
    )

    Artifact = Struct.new(
      :id, :run_id, :step_id, :block_name, :name, :path,
      :content_type, :size_bytes, :checksum, :created_at,
      keyword_init: true
    )
  end
end
