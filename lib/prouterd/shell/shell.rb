module Prouterd
  module Shell
    # Main interactive shell loop.
    #
    # Reads commands from `input`, dispatches to the current mode, prints
    # results to `output` and errors to `error_stream`. The loop is decoupled
    # from terminal I/O: tests pass StringIO; production wraps stdin and
    # uses an isatty check to decide whether to print prompts.
    #
    # Mode return values are interpreted as follows:
    #
    #   :handled       — stay in the current mode
    #   :exit          — pop one mode off the stack; if empty, terminate
    #   :quit          — terminate the shell entirely
    #   :commit        — pop modes back to Privileged, run commit
    #   :abort         — pop modes back to Privileged, run abort
    #   {signal: :enter, mode: <Mode>} — push the new mode onto the stack
    class Shell
      def self.run(session: nil, input: $stdin, output: $stdout, error: $stderr,
                   interactive: nil, banner: true, initial_config_path: nil,
                   store: nil)
        session ||= Session.new(store: store)
        if initial_config_path
          load_initial(session, initial_config_path, error)
        end
        new(
          session: session,
          input: input,
          output: output,
          error: error,
          interactive: interactive.nil? ? input.respond_to?(:isatty) && input.isatty : interactive,
          banner: banner
        ).run
      end

      def self.load_initial(session, path, error)
        source = File.read(path)
        document = Config::Parser.parse(Config::Lexer.tokenize(source))
        result = Config::Validator.validate(document)
        unless result.valid?
          result.errors.each { |e| error.puts "#{path}: #{e}" }
          raise ShellError, "initial config invalid: #{result.errors.length} error(s)"
        end
        session.replace_running(document)
      rescue Errno::ENOENT
        raise ShellError, "initial config not found: #{path}"
      end

      def initialize(session:, input:, output:, error:, interactive:, banner:)
        @session = session
        @input = input
        @output = output
        @error = error
        @interactive = interactive
        @banner = banner
      end

      def run
        @session.mode_stack << Modes::User.new if @session.mode_stack.empty?
        print_banner if @banner && @interactive
        exit_code = 0

        loop do
          mode = current_mode
          break if mode.nil?

          line = read_input(prompt_for(mode))
          break if line.nil? # EOF

          line = line.chomp.strip
          next if line.empty?

          tokens = CommandLine.tokenize(line)
          next if tokens.nil?

          begin
            result = mode.execute(tokens, @session, @output, @error)
            handle_result(result)
          rescue CommandError => e
            @error.puts "% #{e.message}"
            exit_code = 1 unless @interactive
          rescue Prouterd::Config::ConfigError => e
            @error.puts "% #{e.message}"
            exit_code = 1 unless @interactive
          end

          break if @session.mode_stack.empty?
        end

        @output.flush if @output.respond_to?(:flush)
        exit_code
      end

      # Public helper for `prouter exec "<command>"` non-interactive use.
      # Returns the same exit code as run() with input set to a single line.
      def execute_one(input_line)
        @session.mode_stack << Modes::Privileged.new if @session.mode_stack.empty?
        tokens = CommandLine.tokenize(input_line)
        return 0 if tokens.nil?

        result = current_mode.execute(tokens, @session, @output, @error)
        handle_result(result)
        0
      rescue CommandError, Prouterd::Config::ConfigError => e
        @error.puts "% #{e.message}"
        1
      end

      private

      def current_mode
        @session.mode_stack.last
      end

      def prompt_for(mode)
        "#{@session.hostname}#{mode.prompt_suffix} "
      end

      def print_banner
        @output.puts "prouter #{Prouterd::VERSION} — type 'help' for help, 'exit' to leave"
      end

      def read_input(prompt)
        if @interactive && reline_available?
          install_completer
          # Reline provides line editing, history, and Ctrl-C handling
          # without bringing in any extra gem dependency. Returns nil on EOF.
          line = Reline.readline(prompt, true)
          line.nil? ? nil : "#{line}\n"
        else
          if @interactive && @output.respond_to?(:print)
            @output.print(prompt)
            @output.flush if @output.respond_to?(:flush)
          end
          @input.gets
        end
      end

      def reline_available?
        return @reline_available unless @reline_available.nil?

        @reline_available = begin
          require "reline"
          true
        rescue LoadError
          false
        end
      end

      # router-style tab completion. Reline calls completion_proc with the
      # current "word" being completed; we pull the full line via
      # Reline.line_buffer and dispatch through Completer for context-aware
      # suggestions (commands, show targets, process names, run uids, etc.).
      #
      # Token-separator override: by default Reline only uses spaces as word
      # boundaries; that's exactly what we want for `prouter` syntax.
      def install_completer
        return if @completer_installed

        @completer = Completer.new(@session)
        Reline.completion_proc = lambda do |partial|
          line = (Reline.respond_to?(:line_buffer) ? Reline.line_buffer : partial).to_s
          @completer.call(partial.to_s, line)
        end
        # Append a trailing space after a completed token, like a real shell.
        Reline.completion_append_character = " " if Reline.respond_to?(:completion_append_character=)
        @completer_installed = true
      rescue StandardError => e
        @error&.puts("warning: tab completion not installed: #{e.message}")
        @completer_installed = true # don't retry every keystroke
      end

      def handle_result(result)
        case result
        when :handled, nil then nil
        when :exit
          @session.mode_stack.pop
          # If the popped mode was User, the shell is done.
        when :quit
          @session.mode_stack.clear
        when :commit
          run_commit
        when :abort
          run_abort
        when Hash
          if result[:signal] == :enter && result[:mode]
            @session.mode_stack << result[:mode]
          else
            raise ShellError, "unexpected mode result: #{result.inspect}"
          end
        else
          raise ShellError, "unexpected mode result: #{result.inspect}"
        end
      end

      def run_commit
        result = @session.commit_candidate
        if result.valid?
          @output.puts "Commit complete."
          unless result.warnings.empty?
            @output.puts "Warnings:"
            result.warnings.each { |w| @output.puts "  #{w}" }
          end
          # Pop all config sub-modes; return to Privileged.
          @session.mode_stack.pop while @session.mode_stack.last && !@session.mode_stack.last.is_a?(Modes::Privileged)
        else
          @output.puts "Commit failed: #{result.errors.length} error(s)"
          result.errors.each { |e| @output.puts "  #{e}" }
          # Stay where we are so the user can fix and retry.
        end
      end

      def run_abort
        @session.abort_candidate
        @output.puts "Candidate discarded."
        @session.mode_stack.pop while @session.mode_stack.last && !@session.mode_stack.last.is_a?(Modes::Privileged)
      end
    end
  end
end
