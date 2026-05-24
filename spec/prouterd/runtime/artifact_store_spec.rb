require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Prouterd::Runtime::ArtifactStore do
  around do |example|
    Dir.mktmpdir("prouterd-artifact-store-spec-") do |dir|
      @root = File.join(dir, "artifacts")
      @src  = File.join(dir, "src")
      FileUtils.mkdir_p(@src)
      example.run
    end
  end

  let(:store) { described_class.new(@root) }

  def src_file(name, contents)
    path = File.join(@src, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def descriptor(name, host_path, size: nil, content_type: nil, checksum: nil)
    Prouterd::Runner::ArtifactDescriptor.new(
      name: name, host_path: host_path,
      size_bytes: size, content_type: content_type, checksum: checksum
    )
  end

  describe ".default_root" do
    it "uses PROUTERD_ARTIFACTS_ROOT when set" do
      ENV["PROUTERD_ARTIFACTS_ROOT"] = "/tmp/foo-artifacts"
      begin
        expect(described_class.default_root).to eq("/tmp/foo-artifacts")
      ensure
        ENV.delete("PROUTERD_ARTIFACTS_ROOT")
      end
    end

    it "falls back to the compile-time default when the env var is empty" do
      ENV["PROUTERD_ARTIFACTS_ROOT"] = ""
      begin
        expect(described_class.default_root).to eq(described_class::DEFAULT_ROOT)
      ensure
        ENV.delete("PROUTERD_ARTIFACTS_ROOT")
      end
    end

    it "falls back to the compile-time default when the env var is unset" do
      ENV.delete("PROUTERD_ARTIFACTS_ROOT")
      expect(described_class.default_root).to eq(described_class::DEFAULT_ROOT)
    end
  end

  describe "#initialize" do
    it "uses default_root when no root is given" do
      ENV["PROUTERD_ARTIFACTS_ROOT"] = "/somewhere"
      begin
        expect(described_class.new.root).to eq("/somewhere")
      ensure
        ENV.delete("PROUTERD_ARTIFACTS_ROOT")
      end
    end
  end

  describe "#archive" do
    it "returns an empty list for no descriptors without touching the filesystem" do
      result = store.archive("run_x", "block_y", [])
      expect(result).to eq([])
      expect(File.exist?(@root)).to be(false)
    end

    it "creates the run/block dir, copies bytes, and rewrites host_path" do
      src = src_file("payload.bin", "hello-bytes")
      d = descriptor("out.bin", src, size: 11, content_type: "application/octet-stream")

      result = store.archive("run_abc", "scorer", [d])

      expect(result.size).to eq(1)
      archived = result.first
      expect(archived.name).to eq("out.bin")
      expect(archived.host_path).to eq(File.join(@root, "run_abc", "scorer", "out.bin"))
      expect(File.read(archived.host_path)).to eq("hello-bytes")
      # Original descriptor must not be mutated — dup contract.
      expect(d.host_path).to eq(src)
    end

    it "preserves the other descriptor fields verbatim" do
      src = src_file("model.pkl", "x")
      d = descriptor("model.pkl", src, size: 1, content_type: "application/x-pickle", checksum: "abc123")
      archived = store.archive("run1", "train", [d]).first
      expect(archived.size_bytes).to eq(1)
      expect(archived.content_type).to eq("application/x-pickle")
      expect(archived.checksum).to eq("abc123")
    end

    it "supports nested artifact names (forward-slash within name)" do
      src = src_file("nested.txt", "n")
      d = descriptor("sub/dir/n.txt", src)
      archived = store.archive("run9", "blk", [d]).first
      expect(archived.host_path).to eq(File.join(@root, "run9", "blk", "sub", "dir", "n.txt"))
      expect(File.read(archived.host_path)).to eq("n")
    end

    it "refuses artifact names that would escape the archive directory" do
      src = src_file("payload.txt", "secret")
      result = store.archive("run9", "blk", [descriptor("../escape.txt", src)])

      expect(result).to eq([])
      expect(File.exist?(File.join(@root, "run9", "escape.txt"))).to be(false)
    end

    it "refuses symlink sources" do
      target = src_file("target.txt", "secret")
      link = File.join(@src, "link.txt")
      File.symlink(target, link)

      result = store.archive("run9", "blk", [descriptor("link.txt", link)])

      expect(result).to eq([])
      expect(File.exist?(File.join(@root, "run9", "blk", "link.txt"))).to be(false)
    end
  end

  describe "#read" do
    it "returns the file contents when present" do
      src = src_file("a.txt", "alpha")
      store.archive("run1", "b1", [descriptor("a.txt", src)])
      expect(store.read("run1", "b1", "a.txt")).to eq("alpha")
    end

    it "returns nil when the file is missing" do
      expect(store.read("missing-run", "missing-block", "missing.txt")).to be_nil
    end

    it "returns nil for traversal attempts" do
      expect(store.read("run1", "b1", "../outside.txt")).to be_nil
    end
  end

  describe "#list_paths" do
    it "returns [] when the run directory does not exist" do
      expect(store.list_paths("never-archived")).to eq([])
    end

    it "lists files recursively across blocks when no block is given" do
      a = src_file("a.txt", "a"); b = src_file("b.txt", "b"); c = src_file("c.txt", "c")
      store.archive("run1", "blk1", [descriptor("a.txt", a)])
      store.archive("run1", "blk2", [descriptor("nested/b.txt", b), descriptor("c.txt", c)])

      paths = store.list_paths("run1").sort
      expect(paths.size).to eq(3)
      expect(paths).to all(satisfy { |p| File.file?(p) })
      expect(paths.map { |p| p.sub("#{@root}/run1/", "") }).to contain_exactly(
        "blk1/a.txt", "blk2/nested/b.txt", "blk2/c.txt"
      )
    end

    it "scopes to a single block when given" do
      a = src_file("a.txt", "a"); b = src_file("b.txt", "b")
      store.archive("run1", "blk1", [descriptor("a.txt", a)])
      store.archive("run1", "blk2", [descriptor("b.txt", b)])
      paths = store.list_paths("run1", "blk2")
      expect(paths.size).to eq(1)
      expect(paths.first).to end_with("blk2/b.txt")
    end
  end
end
