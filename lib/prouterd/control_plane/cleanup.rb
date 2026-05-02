require "fileutils"
require "time"

module Prouterd
  module ControlPlane
    # Retention sweep for runs / steps / logs / artifacts older than a
    # threshold. Removes BOTH the DB rows and the on-disk artifact files
    # that those rows refer to.
    #
    # Configurable safeguards:
    #   * Only deletes runs in TERMINAL state (success / failed / canceled)
    #     so an unfortunate `--older-than 1m` doesn't kill an active run.
    #   * `--dry-run` mode reports what would be deleted without touching
    #     anything.
    #
    # Config commits are NOT pruned by this command — keeping the audit
    # trail intact is intentional. A separate command can be added if a
    # user explicitly wants commit pruning.
    class Cleanup
      TERMINAL_STATUSES = %w[success failed canceled timeout].freeze

      Result = Struct.new(:runs, :steps, :logs, :artifacts, :artifact_files, :would_delete, keyword_init: true) do
        def total_rows
          runs + steps + logs + artifacts
        end
      end

      def self.sweep(db, older_than:, dry_run: false, artifact_root: nil)
        new(db, older_than: older_than, dry_run: dry_run, artifact_root: artifact_root).sweep
      end

      def initialize(db, older_than:, dry_run: false, artifact_root: nil)
        @db = db
        @older_than = older_than
        @dry_run = dry_run
        @artifact_root = artifact_root || Runtime::ArtifactStore::DEFAULT_ROOT
      end

      def sweep
        cutoff = (Time.now - @older_than).utc.iso8601(3)

        run_ids = @db.execute(
          "SELECT id FROM runs WHERE status IN (#{terminal_in_clause}) AND created_at < ? AND finished_at IS NOT NULL",
          [cutoff]
        ).map(&:first)

        if run_ids.empty?
          return Result.new(runs: 0, steps: 0, logs: 0, artifacts: 0, artifact_files: 0, would_delete: @dry_run)
        end

        run_uids = @db.execute(
          "SELECT uid FROM runs WHERE id IN (#{placeholders(run_ids)})",
          run_ids
        ).map(&:first)

        steps_count = count("run_steps", run_ids)
        logs_count = count("run_logs", run_ids)
        artifacts_count = count("artifacts", run_ids)

        artifact_files_count = run_uids.sum { |uid| count_artifact_files(uid) }

        unless @dry_run
          @db.transaction do
            @db.execute("DELETE FROM run_logs   WHERE run_id IN (#{placeholders(run_ids)})", run_ids)
            @db.execute("DELETE FROM artifacts  WHERE run_id IN (#{placeholders(run_ids)})", run_ids)
            @db.execute("DELETE FROM run_steps  WHERE run_id IN (#{placeholders(run_ids)})", run_ids)
            @db.execute("DELETE FROM runs       WHERE id IN (#{placeholders(run_ids)})", run_ids)
          end
          run_uids.each { |uid| remove_artifact_dir(uid) }
        end

        Result.new(
          runs: run_ids.length,
          steps: steps_count,
          logs: logs_count,
          artifacts: artifacts_count,
          artifact_files: artifact_files_count,
          would_delete: @dry_run
        )
      end

      private

      def terminal_in_clause
        TERMINAL_STATUSES.map { |s| "'#{s}'" }.join(",")
      end

      def placeholders(arr)
        Array.new(arr.length, "?").join(",")
      end

      def count(table, run_ids)
        @db.execute(
          "SELECT COUNT(*) FROM #{table} WHERE run_id IN (#{placeholders(run_ids)})",
          run_ids
        ).first.first
      end

      def count_artifact_files(run_uid)
        dir = File.join(@artifact_root, run_uid)
        return 0 unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*")).count { |p| File.file?(p) }
      end

      def remove_artifact_dir(run_uid)
        dir = File.join(@artifact_root, run_uid)
        FileUtils.remove_entry(dir) if File.directory?(dir)
      end
    end
  end
end
