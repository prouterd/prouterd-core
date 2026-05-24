require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Iface::Mcp::ServerCommand do
  describe ".resolve" do
    it "raises when server_field is not {kind, spec}" do
      expect { described_class.resolve(nil) }.to raise_error(described_class::ResolveError, /kind, spec/)
      expect { described_class.resolve("kind" => "npx") }.to raise_error(described_class::ResolveError)
      expect { described_class.resolve("spec" => "x") }.to raise_error(described_class::ResolveError)
    end

    it "raises when spec is empty (each kind)" do
      %w[npx uvx bin raw].each do |k|
        expect {
          described_class.resolve("kind" => k, "spec" => "")
        }.to raise_error(described_class::ResolveError, /empty/)
      end
    end

    it "npx maps to ['npx','-y','<spec>']" do
      expect(described_class.resolve("kind" => "npx", "spec" => "@a/b"))
        .to eq(["npx", "-y", "@a/b"])
    end

    it "uvx prefers `uv tool run` when uv is on PATH; falls back to plain uvx" do
      allow(described_class).to receive(:executable_on_path?).with("uv").and_return(true)
      expect(described_class.resolve("kind" => "uvx", "spec" => "pkg"))
        .to eq(["uv", "tool", "run", "pkg"])

      allow(described_class).to receive(:executable_on_path?).with("uv").and_return(false)
      expect(described_class.resolve("kind" => "uvx", "spec" => "pkg"))
        .to eq(["uvx", "pkg"])
    end

    it "bin requires absolute paths" do
      expect(described_class.resolve("kind" => "bin", "spec" => "/usr/local/bin/x"))
        .to eq(["/usr/local/bin/x"])
      expect {
        described_class.resolve("kind" => "bin", "spec" => "rel/path")
      }.to raise_error(described_class::ResolveError, /absolute/)
    end

    it "raw shell-splits the spec; empty post-split raises" do
      expect(described_class.resolve("kind" => "raw", "spec" => "a 'b c' d"))
        .to eq(["a", "b c", "d"])
      # A spec of only whitespace passes the empty? check because spec
      # is non-empty; Shellwords.split returns []; we raise.
      expect {
        described_class.resolve("kind" => "raw", "spec" => "   ")
      }.to raise_error(described_class::ResolveError, /empty after shell-split/)
    end

    it "unknown kind raises" do
      expect {
        described_class.resolve("kind" => "ghost", "spec" => "x")
      }.to raise_error(described_class::ResolveError, /unknown server kind/)
    end
  end

  describe ".warn_if_unresolvable" do
    it "returns nil for a non-Hash server_field" do
      expect(described_class.warn_if_unresolvable(nil)).to be_nil
      expect(described_class.warn_if_unresolvable("string")).to be_nil
    end

    it "npx: nil when npx is on PATH, warns otherwise" do
      allow(described_class).to receive(:executable_on_path?).with("npx").and_return(true)
      expect(described_class.warn_if_unresolvable("kind" => "npx", "spec" => "x")).to be_nil

      allow(described_class).to receive(:executable_on_path?).with("npx").and_return(false)
      msg = described_class.warn_if_unresolvable("kind" => "npx", "spec" => "x")
      expect(msg).to include("npx")
    end

    it "uvx: nil when uv or uvx on PATH, warns when neither" do
      allow(described_class).to receive(:executable_on_path?).with("uv").and_return(false)
      allow(described_class).to receive(:executable_on_path?).with("uvx").and_return(true)
      expect(described_class.warn_if_unresolvable("kind" => "uvx", "spec" => "x")).to be_nil

      allow(described_class).to receive(:executable_on_path?).with("uv").and_return(false)
      allow(described_class).to receive(:executable_on_path?).with("uvx").and_return(false)
      expect(described_class.warn_if_unresolvable("kind" => "uvx", "spec" => "x")).to include("uv")
    end

    it "bin: validates absolute / exists / executable" do
      expect(described_class.warn_if_unresolvable("kind" => "bin", "spec" => "rel/path"))
        .to include("must be absolute")
      expect(described_class.warn_if_unresolvable("kind" => "bin", "spec" => "/no/such/x"))
        .to include("does not exist")

      # Existing but non-executable.
      f = Tempfile.create(["non-exec-", ""])
      f.write("x")
      f.close
      File.chmod(0o644, f.path)
      begin
        expect(described_class.warn_if_unresolvable("kind" => "bin", "spec" => f.path))
          .to include("not executable")
      ensure
        File.unlink(f.path)
      end

      # Existing + executable -> nil
      f2 = Tempfile.create(["exec-bin-", ""])
      f2.write("#!/bin/sh\nexit 0\n")
      f2.close
      File.chmod(0o755, f2.path)
      begin
        expect(described_class.warn_if_unresolvable("kind" => "bin", "spec" => f2.path)).to be_nil
      ensure
        File.unlink(f2.path)
      end
    end

    it "raw: always returns a 'cannot be validated' note" do
      expect(described_class.warn_if_unresolvable("kind" => "raw", "spec" => "x"))
        .to include("cannot be validated")
    end

    it "unknown kind: returns nil" do
      expect(described_class.warn_if_unresolvable("kind" => "ghost", "spec" => "x")).to be_nil
    end
  end

  describe ".executable_on_path?" do
    it "returns false for nil / empty input" do
      expect(described_class.executable_on_path?(nil)).to be false
      expect(described_class.executable_on_path?("")).to be false
    end

    it "returns true for a well-known executable on PATH (sh)" do
      expect(described_class.executable_on_path?("sh")).to be true
    end

    it "returns false for an unknown executable" do
      expect(described_class.executable_on_path?("definitely-not-on-path-xyzzy")).to be false
    end
  end
end
