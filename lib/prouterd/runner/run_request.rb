module Prouterd
  module Runner
    # Inputs the orchestrator hands to a Runner. Designed to be runner-agnostic:
    # neither DockerRunner nor StubRunner needs anything beyond these fields.
    RunRequest = Struct.new(
      :run_uid,
      :process_name,
      :block_name,
      :attempt,
      :image,
      :command,        # Optional shell-quoted string
      :env,            # Hash<String, String> — includes PROUTER_* and resolved secrets
      :input_json,     # Ruby Hash — runner serializes to /prouter/input.json
      :timeout_ms,     # Optional Integer
      :network,        # "on" | "off"
      keyword_init: true
    )
  end
end
