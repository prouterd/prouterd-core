module Prouterd
  module Shell
    # Base class for shell modes (User, Privileged, Config, sub-modes).
    #
    # Each Mode owns:
    #   * a prompt suffix (rendered after the hostname)
    #   * a dispatch table mapping head-token -> instance method
    #
    # `execute` returns one of these signals to the Shell loop:
    #
    #   :handled — stay in this mode (default)
    #   :exit    — pop this mode off the stack
    #   :quit    — terminate the shell entirely
    #   :commit  — pop back to privileged, applying candidate as running
    #   :abort   — pop back to privileged, discarding candidate
    #   { :enter, mode } — push the given mode onto the stack
    #
    # CommandError raised inside a handler is caught by Shell, printed to
    # stderr, and the mode stays unchanged.
    class Mode
      def prompt_suffix
        raise NotImplementedError
      end

      # Subclasses override `commands` returning a Hash<String, Symbol>:
      # head-token -> instance method name.
      def commands
        {}
      end

      def execute(tokens, session, out, err)
        head = tokens.first.value
        handler = commands[head]
        unless handler
          raise CommandError, "unknown command '#{head}' in this mode (try 'help')"
        end

        send(handler, tokens, session, out, err)
      end

      def help_lines
        commands.keys.sort.map { |c| "  #{c}" }
      end

      protected

      def values(tokens)
        tokens.map(&:value)
      end

      def expect_arg_count(tokens, count, syntax)
        return if tokens.length == count

        raise CommandError, "syntax: #{syntax}"
      end

      def expect_min_args(tokens, count, syntax)
        return if tokens.length >= count

        raise CommandError, "syntax: #{syntax}"
      end

      def enter(mode)
        { signal: :enter, mode: mode }
      end
    end
  end
end
