# frozen_string_literal: true

require "fileutils"

module Prouterd
  module Runtime
    # Filesystem-backed archive for block artifacts.
    #
    # Layout:
    #   <root>/
    #     <run_uid>/
    #       <block_name>/
    #         <artifact_name>
    #
    # Spec leaves room for an S3/object-store backend later (§21); this class
    # is the minimum viable implementation that the orchestrator uses today.
    # Swap-in is a constructor change.
    class ArtifactStore
      DEFAULT_ROOT = File.join("var", "artifacts").freeze

      attr_reader :root

      # Override the on-disk location with `PROUTERD_ARTIFACTS_ROOT` so
      # operators can mount the daemon's data directory wherever it
      # makes sense (e.g. /var/lib/prouterd/artifacts on a systemd box,
      # /data/artifacts in the container image, an NFS mount in k8s).
      def self.default_root
        env = ENV["PROUTERD_ARTIFACTS_ROOT"]
        env && !env.empty? ? env : DEFAULT_ROOT
      end

      def initialize(root = nil)
        @root = root || self.class.default_root
      end

      # Persist a list of ArtifactDescriptors emitted by a runner. Returns the
      # list with `path` rewritten to the archive location, suitable for
      # storing into the artifacts table.
      def archive(run_uid, block_name, descriptors)
        return [] if descriptors.empty?

        target_dir = File.join(@root, run_uid, block_name)
        FileUtils.mkdir_p(target_dir)
        descriptors.filter_map do |d|
          next unless regular_file_without_symlink?(d.host_path)

          dest = safe_join(target_dir, d.name)
          next unless dest

          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(d.host_path, dest)
          d.dup.tap { |c| c.host_path = dest }
        end
      end

      def read(run_uid, block_name, name)
        path = safe_join(File.join(@root, run_uid, block_name), name)
        return nil unless path

        File.read(path) if File.exist?(path)
      end

      def list_paths(run_uid, block_name = nil)
        base = block_name ? File.join(@root, run_uid, block_name) : File.join(@root, run_uid)
        return [] unless File.directory?(base)

        Dir.glob(File.join(base, "**", "*")).select { |p| File.file?(p) }
      end

      private

      def regular_file_without_symlink?(path)
        return false unless path

        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      rescue SystemCallError
        false
      end

      def safe_join(base, relative_name)
        return nil unless relative_name

        name = relative_name.to_s
        return nil if name.empty? || name.include?("\0") || name.start_with?("/")
        return nil if name.split(/[\\\/]/).any? { |seg| seg == ".." }

        # After absolute-prefix and `..` segment filters above, the
        # expanded path always lives under `base` — defense-in-depth
        # escape check was kept until the agent-flagged coverage gap
        # showed no reachable input exercises its `nil` branch.
        File.expand_path(name, File.expand_path(base))
      end
    end
  end
end
