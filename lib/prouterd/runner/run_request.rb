module Prouterd
  module Runner
    # Inputs the orchestrator hands to a Runner. Common fields are named;
    # runner-type-specific fields live in `type_fields` (a Hash keyed by
    # the plugin's field storage_key). A new runner reads what it needs
    # from `type_fields` — no edits to this struct required.
    RunRequest = Struct.new(
      :run_uid,
      :process_name,
      :block_name,
      :execution_type, # plugin type name — runner is dispatched by this
      :attempt,
      :env,            # Hash<String, String> — includes PROUTER_* and resolved secrets
      :input_json,     # Ruby Hash — runner serializes to {input.json}
      :timeout_ms,     # Optional Integer
      :type_fields,    # Hash<String, Object> — plugin-defined fields (image, exec, ...)
      keyword_init: true
    ) do
      # Convenience for runners that want a single key without typing out
      # `type_fields["foo"]` everywhere. Returns nil for missing keys.
      def field(key)
        (type_fields || {})[key.to_s]
      end
    end
  end
end
