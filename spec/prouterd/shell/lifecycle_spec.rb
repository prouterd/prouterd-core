require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe "Phase 3 config lifecycle through the shell" do
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

  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }

  after { db.close }

  describe "commit persists" do
    it "creates a commit visible in show commits" do
      script = <<~SCRIPT
        enable
        configure terminal
        router demo
        version 1
        exit
        commit
        show commits
        exit
      SCRIPT
      _, out, _, _ = drive(script, store: store)
      expect(out).to include("Commit complete.")
      expect(store.commit_count).to eq(1)
      expect(out).to include("running")
    end

    it "running pointer advances on each commit" do
      script = <<~SCRIPT
        enable
        configure terminal
        router demo
        version 1
        exit
        commit
        configure terminal
        router demo
        version 2
        exit
        commit
        exit
      SCRIPT
      drive(script, store: store)
      expect(store.commit_count).to eq(2)
      latest = store.running_commit
      expect(latest.id).to eq(2)
    end
  end

  describe "write memory" do
    it "blesses running as startup" do
      script = <<~SCRIPT
        enable
        configure terminal
        router demo
        version 1
        exit
        commit
        write memory
        show startup-config
        exit
      SCRIPT
      _, out, _, _ = drive(script, store: store)
      expect(out).to include("Startup configuration saved")
      expect(out).to include("router demo")
      expect(store.startup_commit.id).to eq(store.running_commit.id)
    end

    it "fails clearly when no DB attached" do
      session = Prouterd::Shell::Session.new # no store
      input = StringIO.new("enable\nwrite memory\nexit\n")
      output = StringIO.new
      error = StringIO.new
      Prouterd::Shell::Shell.run(
        session: session,
        input: input, output: output, error: error,
        interactive: false, banner: false
      )
      expect(error.string).to include("no DB attached")
    end
  end

  describe "rollback" do
    it "moves running pointer back to an earlier commit" do
      # Create commits 1 (router a) and 2 (router a + queue).
      drive(<<~SCRIPT, store: store)
        enable
        configure terminal
        router demo
        exit
        commit
        configure terminal
        queue default
        concurrency 5
        timeout 1m
        exit
        commit
        exit
      SCRIPT
      expect(store.running_commit.id).to eq(2)

      _, out, _, _ = drive(<<~SCRIPT, store: store)
        enable
        rollback commit 1
        show running-config
        exit
      SCRIPT
      expect(out).to include("Rolled back running configuration to commit 1")
      expect(out).to include("router demo")
      expect(out).not_to include("queue default")
      expect(store.running_commit.id).to eq(1)
    end

    it "rejects unknown commit id" do
      drive(<<~SCRIPT, store: store)
        enable
        configure terminal
        router demo
        exit
        commit
        exit
      SCRIPT
      _, _out, err, _ = drive("enable\nrollback commit 9999\nexit\n", store: store)
      expect(err).to include("no such commit")
    end
  end

  describe "show commit <id>" do
    it "renders the stored config for a specific commit" do
      drive(<<~SCRIPT, store: store)
        enable
        configure terminal
        router demo
        version 1
        exit
        commit
        configure terminal
        router demo
        version 2
        exit
        commit
        exit
      SCRIPT
      _, out, _, _ = drive("enable\nshow commit 1\nexit\n", store: store)
      expect(out).to include("commit 1")
      expect(out).to include("version 1")
      expect(out).not_to include("version 2")
    end
  end

  describe "boot from existing DB" do
    it "loads running on next session" do
      Tempfile.create(["prouterd-boot-", ".sqlite3"]) do |tmp|
        tmp.close
        db1 = Prouterd::Storage::DB.open(tmp.path)
        store1 = Prouterd::ControlPlane::ConfigStore.new(db1)
        drive(<<~SCRIPT, store: store1)
          enable
          configure terminal
          router persistent
          exit
          commit
          exit
        SCRIPT
        db1.close

        db2 = Prouterd::Storage::DB.open(tmp.path)
        store2 = Prouterd::ControlPlane::ConfigStore.new(db2)
        _, out, _, _ = drive("enable\nshow running-config\nexit\n", store: store2)
        expect(out).to include("router persistent")
        db2.close
      end
    end
  end
end
