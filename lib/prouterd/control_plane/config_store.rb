module Prouterd
  module ControlPlane
    class ConfigStoreError < StandardError; end

    # Facade over the persistence layer for config-lifecycle operations:
    # commits, rollback, write-memory, load-on-boot.
    #
    # The shell talks to ConfigStore via a small interface so it can be
    # swapped or stubbed in tests. ConfigStore owns the lone Repositories::Configs
    # instance for the open DB.
    class ConfigStore
      RUNNING = "running".freeze
      STARTUP = "startup".freeze

      attr_reader :db

      def initialize(db)
        @db = db
        @configs = Storage::Repositories::Configs.new(db)
      end

      # Persist a candidate as a new commit and update the running pointer.
      # Returns the saved Commit. Caller must have validated the document.
      def commit(document, author: nil, message: nil)
        rendered = Config::Renderer.render(document)
        @db.transaction do
          commit = @configs.save_commit(
            rendered_config: rendered,
            author: author,
            message: message
          )
          @configs.set_pointer(RUNNING, commit.id)
          commit
        end
      end

      # Bless the running commit as the startup configuration. Returns the
      # commit that was blessed, or raises if there is no running pointer.
      def write_memory
        running = @configs.get_pointer(RUNNING)
        raise ConfigStoreError, "no running config to save" unless running

        @configs.set_pointer(STARTUP, running.commit_id)
        @configs.get_commit(running.commit_id)
      end

      # Move the running pointer back to a previous commit. Does NOT delete
      # later commits — they remain in history and can be rolled forward to.
      def rollback(commit_id)
        commit = @configs.get_commit(commit_id)
        raise ConfigStoreError, "no such commit #{commit_id}" unless commit

        @configs.set_pointer(RUNNING, commit_id)
        commit
      end

      # Returns the AST::Document currently pointed at by `running`, or
      # an empty Document if nothing has been committed yet.
      def load_running
        load_pointer(RUNNING)
      end

      def load_startup
        load_pointer(STARTUP)
      end

      def running_commit
        running = @configs.get_pointer(RUNNING)
        running && @configs.get_commit(running.commit_id)
      end

      def startup_commit
        startup = @configs.get_pointer(STARTUP)
        startup && @configs.get_commit(startup.commit_id)
      end

      def get_commit(id)
        @configs.get_commit(id)
      end

      def list_commits(limit: 50)
        @configs.list_commits(limit: limit)
      end

      def commit_count
        @configs.count_commits
      end

      private

      def load_pointer(name)
        ptr = @configs.get_pointer(name)
        return Config::AST::Document.new unless ptr

        commit = @configs.get_commit(ptr.commit_id)
        return Config::AST::Document.new unless commit

        lines = Config::Lexer.tokenize(commit.rendered_config)
        Config::Parser.parse(lines)
      end
    end
  end
end
