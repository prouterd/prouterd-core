module Prouterd
  module Storage
    JOB_STATUSES = %w[queued locked completed failed dead].freeze

    Job = Struct.new(
      :id, :run_id, :kind, :status, :attempts, :locked_by, :locked_at,
      :available_at, :payload_json, :error_message, :created_at, :updated_at,
      keyword_init: true
    ) do
      def payload
        return {} if payload_json.nil? || payload_json.empty?

        JSON.parse(payload_json)
      end
    end
  end
end
