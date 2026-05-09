require "spec_helper"
require "stringio"
require "tempfile"

# Config-lifecycle through the shell, via the imperative `apply` /
# `rollback commit` / `write memory` commands. The interactive
# `configure terminal` candidate-config flow was removed — the
# canonical path is now: edit `.prc` in your editor, `apply <file>`.
RSpec.describe "config lifecycle through the shell" do
  def drive(script, store:)
    input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
    output = StringIO.new
    error  = StringIO.new
    session = Prouterd::Shell::Session.new(store: store)
    code = Prouterd::Shell::Shell.run(
      session: session,
      input: input, output: output, error: error,
      interactive: false, banner: false
    )
    [code, output.string, error.string, session]
  end

  def write_prc(text)
    f = Tempfile.create(["lifecycle-", ".prc"])
    f.write(text)
    f.flush
    f.close
    f.path
  end

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }

  after { db.close }

  let(:v1_prc) do
    write_prc(<<~PRC)
      router demo
       version 1
      exit
    PRC
  end

  let(:v2_prc) do
    write_prc(<<~PRC)
      router demo
       version 2
      exit
    PRC
  end

  describe "apply persists" do
    it "creates a commit visible in show commits" do
      _, out, _, _ = drive("enable\napply #{v1_prc}\nshow commits\nexit\n", store: store)
      expect(out).to match(/Applied .*\.prc as commit \d/)
      expect(store.commit_count).to eq(1)
      expect(out).to include("running")
    end

    it "running pointer advances on each apply" do
      drive("enable\napply #{v1_prc}\napply #{v2_prc}\nexit\n", store: store)
      expect(store.commit_count).to eq(2)
      latest = store.running_commit
      expect(latest.id).to eq(2)
      doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(latest.rendered_config))
      expect(doc.router.version).to eq(2)
    end
  end

  describe "write memory" do
    it "blesses running as startup" do
      _, out, _, _ = drive("enable\napply #{v1_prc}\nwrite memory\nshow startup-config\nexit\n", store: store)
      expect(out).to include("Startup configuration saved")
      expect(out).to include("router demo")
      expect(out).to include("version 1")
    end

    it "fails clearly when no DB attached" do
      _, _out, err = drive("enable\nwrite memory\nexit\n", store: nil)
      expect(err).to include("no DB attached")
    end
  end

  describe "rollback" do
    it "moves running pointer back to an earlier commit" do
      drive("enable\napply #{v1_prc}\napply #{v2_prc}\nexit\n", store: store)
      expect(store.running_commit.id).to eq(2)

      _, out, _, _ = drive("enable\nrollback commit 1\nshow running-config\nexit\n", store: store)
      expect(out).to include("Rolled back")
      expect(out).to include("version 1")
      expect(store.running_commit.id).to eq(1)
    end

    it "rejects unknown commit id" do
      _, _out, err, _ = drive("enable\nrollback commit 999\nexit\n", store: store)
      expect(err).to include("no such commit")
    end
  end

  describe "show commit <id>" do
    it "renders the stored config for a specific commit" do
      drive("enable\napply #{v1_prc}\nexit\n", store: store)
      _, out, _, _ = drive("enable\nshow commit 1\nexit\n", store: store)
      expect(out).to include("router demo")
      expect(out).to include("version 1")
    end
  end

  describe "boot from existing DB" do
    it "loads running on next session" do
      drive("enable\napply #{v1_prc}\nexit\n", store: store)
      _, out, _, _ = drive("enable\nshow running-config\nexit\n", store: store)
      expect(out).to include("router demo")
      expect(out).to include("version 1")
    end
  end
end
