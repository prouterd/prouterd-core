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
      attr_reader :store, :last_commit

      DEFAULT_HOSTNAME = "process-router".freeze

      # `store` is an optional ControlPlane::ConfigStore. When provided:
      #   - The constructor loads running_config from the store's running pointer
      #     (unless an explicit running_config argument is given).
      #   - commit_candidate persists a new commit and updates the running pointer.
      #   - rollback / write_memory delegate to the store.
      # Without a store, the Session is in-memory-only (Phase 2 mode).
      def initialize(running_config: nil, store: nil)
        @store = store
        @running_config =
          if running_config
            running_config
          elsif store
            store.load_running
          else
            Config::AST::Document.new
          end
        @candidate_config = nil
        @mode_stack = []
        @last_commit = store&.running_commit
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

      # Validate the candidate and, if valid, swap it into running. When a
      # store is attached, also persist a new commit and update the running
      # pointer atomically. Returns a Validator::Result.
      def commit_candidate(author: nil, message: nil)
        raise ShellError, "no candidate to commit" unless in_config_mode?

        result = Config::Validator.validate(@candidate_config)
        return result unless result.valid?

        if @store
          @last_commit = @store.commit(@candidate_config, author: author, message: message)
        end
        @running_config = @candidate_config
        @candidate_config = nil
        result
      end

      def rollback_to(commit_id)
        raise ShellError, "rollback requires a config store" unless @store
        raise ShellError, "cannot rollback while in config mode; commit or abort first" if in_config_mode?

        commit = @store.rollback(commit_id)
        # Reload running from the store so AST and pointer agree.
        @running_config = @store.load_running
        @last_commit = commit
        commit
      end

      def write_memory
        raise ShellError, "write memory requires a config store" unless @store
        @store.write_memory
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
