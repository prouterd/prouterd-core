# frozen_string_literal: true

require "sqlite3"
require "fileutils"
require "set"
require "time"

module Prouterd
  module Storage
    class StorageError < StandardError; end

    # Disk is full / read-only / SQLite I/O failed. The daemon flips
    # itself into "stop accepting" mode on this so /i/* and /v1/*-mutate
    # endpoints return 503 rather than partial-write the DB. The
    # scheduler periodically re-probes and flips back when writes work.
    class DiskUnavailableError < StorageError; end

    # Thin wrapper around SQLite3::Database that:
    #   * ensures the parent directory exists (and creates it for relative paths
    #     like `var/prouterd.db`)
    #   * enables foreign keys and WAL journaling
    #   * runs pending migrations on open
    #   * exposes a `.transaction` helper that's no-op-safe to nest
    #   * translates disk-full / I/O exceptions into DiskUnavailableError
    #
    # All higher-level repositories receive a DB instance — never sqlite3
    # directly — so swapping in another backend later means re-implementing
    # this class, not every query site.
    class DB
      DEFAULT_PATH = File.join("var", "prouterd.db").freeze

      # SQLite3 exception classes that mean "the storage layer is not
      # currently writable". On any of these, callers should fail the
      # request fast rather than retry blindly. ENOSPC is the host
      # filesystem; the SQLite3 ones surface from libsqlite3 itself.
      DISK_UNAVAILABLE_EXCEPTIONS = [
        Errno::ENOSPC,
        SQLite3::IOException,
        SQLite3::FullException,
        SQLite3::ReadOnlyException
      ].freeze

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
        @sqlite.execute(sql, normalize_params(params))
      rescue *DISK_UNAVAILABLE_EXCEPTIONS => e
        raise DiskUnavailableError, "storage write failed (#{e.class}): #{e.message}"
      end

      def execute_batch(sql)
        @sqlite.execute_batch(sql)
      rescue *DISK_UNAVAILABLE_EXCEPTIONS => e
        raise DiskUnavailableError, "storage write failed (#{e.class}): #{e.message}"
      end

      # Cheap probe used by the daemon's accepting-state monitor. Issues
      # a SELECT 1 and a write attempt inside an immediate transaction
      # that's rolled back — exercises both reader and writer paths
      # without leaving any rows behind. Returns true on success, false
      # if the storage is genuinely unwritable (disk full, read-only,
      # I/O error). A SQLite BUSY result counts as healthy — there ARE
      # writers, the storage works, this probe is just losing the
      # contention race.
      def healthy?
        @sqlite.execute("SELECT 1")
        @sqlite.execute("BEGIN IMMEDIATE")
        @sqlite.execute("ROLLBACK")
        true
      rescue *DISK_UNAVAILABLE_EXCEPTIONS
        @sqlite.execute("ROLLBACK") rescue nil
        false
      rescue SQLite3::BusyException
        @sqlite.execute("ROLLBACK") rescue nil
        true
      end

      def query_row(sql, params = [])
        rows = execute(sql, params)
        rows.first
      end

      # ASCII-8BIT strings (from Rack path segments, file reads in binary mode,
      # network buffers) are bound as BLOB by sqlite3, and BLOB != TEXT in
      # parameterized comparisons. Force UTF-8 on every string param so callers
      # never have to think about it.
      def normalize_params(params)
        params.map do |p|
          if p.is_a?(String) && p.encoding != Encoding::UTF_8
            p.dup.force_encoding(Encoding::UTF_8)
          else
            p
          end
        end
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
