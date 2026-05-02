require "sqlite3"
require "fileutils"
require "set"
require "time"

module Prouterd
  module Storage
    class StorageError < StandardError; end

    # Thin wrapper around SQLite3::Database that:
    #   * ensures the parent directory exists (and creates it for relative paths
    #     like `var/prouterd.db`)
    #   * enables foreign keys and WAL journaling
    #   * runs pending migrations on open
    #   * exposes a `.transaction` helper that's no-op-safe to nest
    #
    # All higher-level repositories receive a DB instance — never sqlite3
    # directly — so swapping in another backend later means re-implementing
    # this class, not every query site.
    class DB
      DEFAULT_PATH = File.join("var", "prouterd.db").freeze

      attr_reader :path

      def self.open(path = DEFAULT_PATH, run_migrations: true)
        new(path, run_migrations: run_migrations)
      end

      def initialize(path, run_migrations: true)
        @path = path
        ensure_directory(path) unless path == ":memory:"

        @sqlite = SQLite3::Database.new(path)
        @sqlite.results_as_hash = false
        @sqlite.execute("PRAGMA foreign_keys = ON;")
        @sqlite.execute("PRAGMA journal_mode = WAL;") unless path == ":memory:"
        @sqlite.execute("PRAGMA synchronous = NORMAL;")

        Migrations.run(self) if run_migrations
      end

      # ----- delegation to underlying SQLite3::Database -----

      def execute(sql, params = [])
        @sqlite.execute(sql, params)
      end

      def execute_batch(sql)
        @sqlite.execute_batch(sql)
      end

      def query_row(sql, params = [])
        rows = execute(sql, params)
        rows.first
      end

      def last_insert_row_id
        @sqlite.last_insert_row_id
      end

      def transaction
        if @sqlite.transaction_active?
          yield self
        else
          @sqlite.transaction do
            yield self
          end
        end
      end

      def close
        @sqlite&.close
      end

      def closed?
        @sqlite.nil? || @sqlite.closed?
      end

      private

      def ensure_directory(path)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless dir.empty? || File.directory?(dir)
      end
    end
  end
end
