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

      def initialize(root = DEFAULT_ROOT)
        @root = root
      end

      # Persist a list of ArtifactDescriptors emitted by a runner. Returns the
      # list with `path` rewritten to the archive location, suitable for
      # storing into the artifacts table.
      def archive(run_uid, block_name, descriptors)
        return [] if descriptors.empty?

        target_dir = File.join(@root, run_uid, block_name)
        FileUtils.mkdir_p(target_dir)
        descriptors.map do |d|
          dest = File.join(target_dir, d.name)
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(d.host_path, dest)
          d.dup.tap { |c| c.host_path = dest }
        end
      end

      def read(run_uid, block_name, name)
        path = File.join(@root, run_uid, block_name, name)
        File.read(path) if File.exist?(path)
      end

      def list_paths(run_uid, block_name = nil)
        base = block_name ? File.join(@root, run_uid, block_name) : File.join(@root, run_uid)
        return [] unless File.directory?(base)

        Dir.glob(File.join(base, "**", "*")).select { |p| File.file?(p) }
      end
    end
  end
end
