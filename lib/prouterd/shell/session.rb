module Prouterd
  module Shell
    # The Session holds all per-shell-instance state:
    #
    #   * running_config — the active AST::Document
    #   * candidate_config — clone of running while inside `configure terminal`,
    #     nil otherwise
    #   * mode_stack — stack of Mode objects driving the prompt and dispatch
    #
    # All edits during a config session mutate `candidate_config`. `commit`
    # validates and swaps it into running. `abort` discards it. This matches
    # Candidate-config-style commit semantics, not router CLI's apply-live model.
    class Session
      attr_accessor :running_config, :candidate_config, :mode_stack
      attr_reader :startup_path

      DEFAULT_HOSTNAME = "process-router".freeze

      def initialize(running_config: nil, startup_path: nil)
        @running_config = running_config || Config::AST::Document.new
        @candidate_config = nil
        @mode_stack = []
        @startup_path = startup_path
      end

      def hostname
        config = active_config
        config.router&.hostname || DEFAULT_HOSTNAME
      end

      # The "active" config for editing/showing during a session:
      #   - In config mode: candidate
      #   - Otherwise:      running
      def active_config
        @candidate_config || @running_config
      end

      def in_config_mode?
        !@candidate_config.nil?
      end

      # Begin editing: deep-clone running into candidate.
      # Marshal-based clone is sufficient because AST nodes are plain Ruby
      # objects with no IO/procs.
      def begin_candidate
        raise ShellError, "already in config mode" if in_config_mode?

        @candidate_config = deep_clone(@running_config)
      end

      # Validate the candidate and, if valid, swap it into running. Returns
      # a Validator::Result so callers can render errors on failure.
      def commit_candidate
        raise ShellError, "no candidate to commit" unless in_config_mode?

        result = Config::Validator.validate(@candidate_config)
        return result unless result.valid?

        @running_config = @candidate_config
        @candidate_config = nil
        result
      end

      def abort_candidate
        raise ShellError, "no candidate to abort" unless in_config_mode?

        @candidate_config = nil
      end

      # Replace running config wholesale (used by `load <file>`). This bypasses
      # the candidate flow because it's a top-level "load fresh" operation.
      # Validation is the caller's responsibility.
      def replace_running(document)
        raise ShellError, "cannot load while in config mode; commit or abort first" if in_config_mode?

        @running_config = document
      end

      private

      def deep_clone(document)
        Marshal.load(Marshal.dump(document))
      end
    end
  end
end
