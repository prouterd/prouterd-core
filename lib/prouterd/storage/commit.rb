# frozen_string_literal: true

module Prouterd
  module Storage
    # Persisted config commit row.
    #
    # `id` is also the user-facing commit number — `rollback commit 17`,
    # `show commit 17` use this value. Auto-incremented on insert; never reused.
    Commit = Struct.new(
      :id,
      :checksum,
      :author,
      :message,
      :rendered_config,
      :compiled_config_json,
      :created_at,
      keyword_init: true
    ) do
      # Short SHA-style display: first 12 chars of checksum.
      def short_checksum
        checksum&.slice(0, 12)
      end
    end

    Pointer = Struct.new(:name, :commit_id, :updated_at, keyword_init: true)
  end
end
