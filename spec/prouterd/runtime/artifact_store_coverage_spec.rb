require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Prouterd::Runtime::ArtifactStore do
  around do |example|
    Dir.mktmpdir("prouterd-artifact-cov-") do |dir|
      @root = File.join(dir, "artifacts")
      @src  = File.join(dir, "src")
      FileUtils.mkdir_p(@src)
      example.run
    end
  end

  let(:store) { described_class.new(@root) }

  def descriptor(name, host_path)
    Prouterd::Runner::ArtifactDescriptor.new(name: name, host_path: host_path)
  end

  describe "#archive" do
    it "skips a descriptor whose host_path is nil (regular_file_without_symlink? early return)" do
      result = store.archive("run1", "blk", [descriptor("out.bin", nil)])
      expect(result).to eq([])
    end

    it "skips a descriptor whose host_path doesn't exist (SystemCallError rescue)" do
      result = store.archive("run1", "blk", [descriptor("out.bin", "/nonexistent_/__nope__.bin")])
      expect(result).to eq([])
    end

    it "refuses an empty artifact name (safe_join early return)" do
      src = File.join(@src, "in.txt")
      File.write(src, "x")
      result = store.archive("run1", "blk", [descriptor("", src)])
      expect(result).to eq([])
    end

    it "refuses an absolute artifact name (safe_join early return)" do
      src = File.join(@src, "in.txt")
      File.write(src, "x")
      result = store.archive("run1", "blk", [descriptor("/etc/passwd", src)])
      expect(result).to eq([])
    end

    it "refuses an artifact name containing a NUL byte" do
      src = File.join(@src, "in.txt")
      File.write(src, "x")
      result = store.archive("run1", "blk", [descriptor("a\0b", src)])
      expect(result).to eq([])
    end
  end

  describe "#read" do
    it "returns nil for an empty name (safe_join short-circuit)" do
      expect(store.read("run1", "blk", "")).to be_nil
    end

    it "returns nil for an absolute name (safe_join short-circuit)" do
      expect(store.read("run1", "blk", "/etc/passwd")).to be_nil
    end

    it "returns nil when called with a nil name (safe_join: relative_name nil)" do
      expect(store.read("run1", "blk", nil)).to be_nil
    end
  end
end
