require_relative "shell/errors"
require_relative "shell/command_line"
require_relative "shell/session"
require_relative "shell/show"
require_relative "shell/mode"

# Modes — order matters for require_relative because Config mode references
# the sub-modes by class name during command dispatch.
require_relative "shell/modes/section"
require_relative "shell/modes/config_block"
require_relative "shell/modes/config_process_route"
require_relative "shell/modes/config_global_route"
require_relative "shell/modes/config_process"
require_relative "shell/modes/config"
require_relative "shell/modes/privileged"
require_relative "shell/modes/user"

require_relative "shell/shell"

module Prouterd
  module Shell
  end
end
