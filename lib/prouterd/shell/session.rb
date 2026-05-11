# frozen_string_literal: true

module Prouterd
  module Shell
    # The Session holds all per-shell-instance state:
    #
    #   * running_config — the active AST::Document
    #   * mode_stack — stack of Mode objects driving the prompt and dispatch
    #
    # The interactive `configure terminal` candidate-config flow was
    # removed; operators edit `.prc` files in their preferred editor
    # and `apply` them as new commits.
    class Session
      attr_accessor :running_config, :mode_stack
      attr_reader :store, :last_commit, :runner, :artifact_store

      DEFAULT_HOSTNAME = "process-router".freeze

      # `store`           — optional ControlPlane::ConfigStore for persistence.
      # `runner`          — optional Runner for executing blocks (Phase 4+).
      #                     If nil, `trigger` raises with a clear message.
      # `artifact_store`  — optional Runtime::ArtifactStore; defaults are
      #                     created on demand by the orchestrator.
      def initialize(running_config: nil, store: nil, runner: nil, artifact_store: nil)
        @store = store
        @runner = runner
        @artifact_store = artifact_store
        @running_config =
          if running_config
            running_config
          elsif store
            store.load_running
          else
            Config::AST::Document.new
          end
        @mode_stack = []
        @last_commit = store&.running_commit
      end

      def orchestrator
        raise ShellError, "no DB attached; trigger requires --db" unless @store
        raise ShellError, "no runner configured; pass --runner=docker|stub" unless @runner

        @orchestrator ||= Runtime::Orchestrator.new(
          db: @store.db,
          runner: @runner,
          artifact_store: @artifact_store
        )
      end

      # Replay a previous run with the same input event and the same config
      # commit it was originally pinned to. Returns the new Run.
      def replay(run_uid)
        original, document = load_replay_context(run_uid)
        event = original.input_event_json ? JSON.parse(original.input_event_json) : {}

        orchestrator.trigger(
          document,
          original.process_name,
          input_event: event,
          interface_name: original.interface_name,
          commit_id: original.process_config_commit_id,
          replay_of_run_id: original.id
        )
      end

      # Replay starting AT a specific block. Seeds the new run's context with
      # the snapshot captured in the original step's input_json, so downstream
      # blocks see exactly what they would have seen on the original run.
      def replay_from(run_uid, block_name)
        original, document = load_replay_context(run_uid)
        repo = Storage::Repositories::Runs.new(@store.db)

        # Pick the EARLIEST attempt's row for the chosen block — that's the
        # one with the original input_json before any retry mutation.
        target_step = repo.list_steps(original.id).find { |s| s.block_name == block_name }
        unless target_step
          raise ShellError, "block '#{block_name}' did not run in '#{run_uid}'; cannot replay from it"
        end
        unless target_step.input_json
          raise ShellError, "step '#{block_name}' has no captured input; cannot replay from it"
        end

        payload = JSON.parse(target_step.input_json)
        seed = payload["context"] || {}

        new_run = orchestrator.enqueue(
          document,
          original.process_name,
          input_event: payload["context"]&.dig("event") || (original.input_event_json ? JSON.parse(original.input_event_json) : {}),
          interface_name: original.interface_name,
          commit_id: original.process_config_commit_id,
          replay_of_run_id: original.id
        )
        orchestrator.execute_run(new_run, document, from_block: block_name, seed_context: seed)
        Storage::Repositories::Runs.new(@store.db).get_run(new_run.id)
      end

      def hostname
        config = active_config
        config.router&.hostname || DEFAULT_HOSTNAME
      end

      # The "active" config the shell is reading. With the interactive
      # config-mode editor removed, this is just the running config.
      # Kept as its own method so callers don't need to know which
      # underlying field to read.
      def active_config
        @running_config
      end

      def rollback_to(commit_id)
        raise ShellError, "rollback requires a config store" unless @store

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

      # Replace running config wholesale (used by `load <file>` / `apply
      # <file>`). The Validator::Result is the caller's concern.
      def replace_running(document)
        @running_config = document
      end

      private

      def load_replay_context(run_uid)
        raise ShellError, "no DB attached; replay requires --db" unless @store

        repo = Storage::Repositories::Runs.new(@store.db)
        original = repo.get_run_by_uid(run_uid)
        raise ShellError, "no such run '#{run_uid}'" unless original
        unless original.process_config_commit_id
          raise ShellError, "run '#{run_uid}' was not pinned to a config commit; cannot replay"
        end

        commit = @store.get_commit(original.process_config_commit_id)
        raise ShellError, "config commit #{original.process_config_commit_id} no longer exists" unless commit

        document = Config::Parser.parse(Config::Lexer.tokenize(commit.rendered_config))
        [original, document]
      end
    end
  end
end
