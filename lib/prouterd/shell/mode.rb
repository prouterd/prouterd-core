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
    #   :end     — pop back to privileged, leaving candidate intact (router `end`)
    #   { :enter, mode } — push the given mode onto the stack
    #
    # CommandError raised inside a handler is caught by Shell, printed to
    # stderr, and the mode stays unchanged.
    #
    # # router-style command resolution
    #
    # `Mode#execute` does three router-flavored things before dispatch:
    #
    #   1. Bare `?` runs the mode's help.
    #   2. A trailing `?` (e.g. `show ?`, `show run ?`) is intercepted as
    #      context-sensitive help: the Completer is asked what could come
    #      next, and that list is printed.
    #   3. Otherwise, the head token is resolved against `commands.keys`
    #      first by exact match, then by unique prefix expansion. So
    #      `sh run`, `conf t`, `wr m`, `dis` all resolve. An ambiguous
    #      prefix raises CommandError listing the candidates.
    #
    # If the head still doesn't resolve, `apply_field(tokens, session)` is
    # called. The base class raises "unknown command"; sub-modes that act
    # as field editors override it to delegate to the file parser.
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

        if head == "?" && tokens.length == 1
          return invoke_help(tokens, session, out, err)
        end

        if tokens.length > 1 && tokens.last.value == "?"
          return show_context_help(tokens[0..-2], session, out)
        end

        expanded = expand_prefix(head, commands.keys)
        handler = expanded ? commands[expanded] : nil

        if handler
          if expanded != head
            tokens = tokens.dup
            tokens[0] = rebuild_head_token(tokens[0], expanded)
          end
          send(handler, tokens, session, out, err)
        else
          apply_field(tokens, session)
        end
      end

      def help_lines
        commands.keys.sort.map { |c| "  #{c}" }
      end

      # Sub-modes that act as field editors override this to delegate to the
      # file parser. Default: bail out with a clear error.
      def apply_field(tokens, _session)
        raise CommandError, "unknown command '#{tokens.first.value}' in this mode (try 'help' or '?')"
      end

      # router `do <command>` — run a privileged-mode command from inside any
      # config sub-mode without exiting first. Mode-changing commands
      # (`configure`, `disable`, `exit`, etc.) are rejected so the user can't
      # accidentally push or pop modes via `do`.
      def run_do(tokens, session, out, err)
        if tokens.length < 2
          raise CommandError, "syntax: do <command> [args...]"
        end

        result = Modes::Privileged.new.execute(tokens[1..], session, out, err)

        case result
        when :handled, nil
          :handled
        when Hash, :exit, :quit, :commit, :abort, :end
          raise CommandError, "'do' cannot run mode-changing commands"
        else
          :handled
        end
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

      # router-style keyword match for the multi-word arguments inside a
      # command (e.g. `configure terminal` -> `conf t`). Empty / nil never
      # matches; the actual must be a non-empty prefix of expected.
      def match_keyword?(actual, expected)
        return false if actual.nil? || actual.empty?
        return true if actual == expected

        expected.start_with?(actual)
      end

      def enter(mode)
        { signal: :enter, mode: mode }
      end

      # router unique-prefix expansion. Exact match always wins over prefix
      # match; that lets `do` and `down` coexist (typing `do` resolves as
      # `do`, not as a prefix of `down`). An ambiguous prefix raises.
      def expand_prefix(head, names)
        return head if names.include?(head)

        matches = names.select { |n| n.is_a?(String) && n.length > head.length && n.start_with?(head) }
        case matches.length
        when 0 then nil
        when 1 then matches.first
        else
          raise CommandError, "ambiguous command '#{head}': #{matches.sort.join(', ')}"
        end
      end

      # Trailing-`?` context help. Asks the Completer what tokens could come
      # after `prefix_tokens` and prints them, one per line. router CLIs print
      # `<cr>` when there is no further input expected — we mirror that.
      def show_context_help(prefix_tokens, session, out)
        line = prefix_tokens.map(&:value).join(" ") + " "
        candidates = Completer.new(session).call("", line)
        if candidates.empty?
          out.puts "  <cr>"
        else
          candidates.each { |c| out.puts "  #{c}" }
        end
        :handled
      end

      def invoke_help(tokens, session, out, err)
        handler = commands["help"] || commands["?"]
        return :handled unless handler

        send(handler, tokens, session, out, err)
      end

      # Rebuild the head token with the expanded value so handlers that
      # inspect tokens[0].value see the canonical command name. Token has
      # a positional initializer (kind, value, line, column).
      def rebuild_head_token(prototype, value)
        Prouterd::Config::Token.new(prototype.type, value, prototype.line, prototype.column)
      end
    end
  end
end
