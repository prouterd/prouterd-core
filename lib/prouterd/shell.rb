# frozen_string_literal: true

require_relative "shell/errors"
require_relative "shell/command_line"
require_relative "shell/session"
require_relative "shell/table"
require_relative "shell/show"
require_relative "shell/mode"

# Modes — read-only operator surface (`enable`, `show *`, imperative
# top-level commands like `apply file.prc` / `rollback commit X`).
# Interactive `configure terminal` candidate-config flow was removed;
# operators edit `.prc` in their editor and `prouter apply` instead.
require_relative "shell/modes/privileged"
require_relative "shell/modes/user"

require_relative "shell/completer"
require_relative "shell/shell"

module Prouterd
  module Shell
  end
end
