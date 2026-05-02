module Prouterd
  module Runner
    # Inputs the orchestrator hands to a Runner. Designed to be runner-agnostic:
    # DockerRunner / ShellRunner / StubRunner all consume the same shape.
    RunRequest = Struct.new(
      :run_uid,
      :process_name,
      :block_name,
      :execution_type, # "docker" | "shell" — runner picks based on this
      :attempt,
      :image,
      :command,        # Optional shell-quoted string (Docker only)
      :env,            # Hash<String, String> — includes PROUTER_* and resolved secrets
      :input_json,     # Ruby Hash — runner serializes to {input.json}
      :timeout_ms,     # Optional Integer
      :network,        # "on" | "off"
      :cwd,            # Optional String — shell cwd
      :shell_path,     # Optional String — shell binary (defaults to /bin/sh via Open3)
      :pull,           # Optional String — Docker pull policy
      :user,           # Optional String — Docker user
      :memory,         # Optional String — Docker memory limit
      :cpu,            # Optional String — Docker CPU limit
      keyword_init: true
    )
  end
end
