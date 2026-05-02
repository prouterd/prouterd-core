module Prouterd
  module Shell
    class ShellError < StandardError; end

    # Raised by mode handlers to indicate a user-visible command error.
    # The Shell loop catches it, prints the message to stderr, and continues
    # in the same mode (no state changes).
    class CommandError < ShellError; end
  end
end
