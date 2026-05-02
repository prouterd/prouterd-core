require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe Prouterd::Shell::Shell do
  # Drives the shell with a scripted input string. Returns [exit_code, stdout, stderr].
  def drive(script, session: nil, banner: false)
    input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
    output = StringIO.new
    error  = StringIO.new
    session ||= Prouterd::Shell::Session.new
    code = described_class.run(
      session: session,
      input: input,
      output: output,
      error: error,
      interactive: false,
      banner: banner
    )
    [code, output.string, error.string]
  end

  def loaded_session(fixture: "sales_ops.prc")
    doc = Prouterd::Config::Parser.parse(
      Prouterd::Config::Lexer.tokenize(read_fixture(fixture))
    )
    Prouterd::Shell::Session.new(running_config: doc)
  end

  describe "user mode" do
    it "exits cleanly on `exit`" do
      code, _, _ = drive("exit\n")
      expect(code).to eq(0)
    end

    it "blocks privileged shows in user mode" do
      _, _out, err = drive("show running-config\nexit\n")
      expect(err).to include("requires privileged mode")
    end

    it "allows show version in user mode" do
      _, out, _ = drive("show version\nexit\n")
      expect(out).to include("prouter #{Prouterd::VERSION}")
    end

    it "treats EOF as exit" do
      input  = StringIO.new("show version\n")
      output = StringIO.new
      error  = StringIO.new
      code = described_class.run(
        session: Prouterd::Shell::Session.new,
        input: input, output: output, error: error,
        interactive: false, banner: false
      )
      expect(code).to eq(0)
    end
  end

  describe "privileged mode" do
    it "shows running-config from a loaded session" do
      _, out, _ = drive("enable\nshow running-config\nexit\n", session: loaded_session)
      expect(out).to include("router sales_ops")
      expect(out).to include("interface webhook leads_in")
    end

    it "lists processes" do
      _, out, _ = drive("enable\nshow processes\nexit\n", session: loaded_session)
      expect(out).to include("lead_pipeline")
      expect(out).to include("BLOCKS")
    end

    it "shows process detail" do
      _, out, _ = drive("enable\nshow process lead_pipeline\nexit\n", session: loaded_session)
      expect(out).to include("blocks (4)")
      expect(out).to include("extract  image=registry.local/blocks/extract-lead:v1")
    end

    it "shows interface detail" do
      _, out, _ = drive("enable\nshow interface leads_in\nexit\n", session: loaded_session)
      expect(out).to include("path:     /leads")
      expect(out).to include("method:   POST")
    end

    it "lists secrets without revealing values" do
      _, out, _ = drive("enable\nshow secrets\nexit\n", session: loaded_session)
      expect(out).to include("WEBHOOK_TOKEN")
      expect(out).to include("CLEARBIT_API_KEY")
      # No secret values appear (they're env-sourced; we show env name only).
      expect(out).not_to match(/secret value/i)
    end

    it "load command replaces running config" do
      Tempfile.create(["mini", ".prc"]) do |tmp|
        tmp.write(read_fixture("minimal.prc"))
        tmp.flush
        _, out, _ = drive("enable\nload #{tmp.path}\nshow running-config\nexit\n")
        expect(out).to include("Loaded #{tmp.path}")
        expect(out).to include("router demo")
      end
    end

    it "load reports validation failure" do
      Tempfile.create(["bad", ".prc"]) do |tmp|
        tmp.write("router x\nexit\nprocess p\nexit\n")
        tmp.flush
        _, out, err = drive("enable\nload #{tmp.path}\nexit\n")
        expect(out).to include("has no blocks")
        expect(err).to include("load failed")
      end
    end
  end

  describe "configure terminal flow" do
    it "creates and commits a router-only config" do
      _, out, _ = drive(<<~SCRIPT, session: Prouterd::Shell::Session.new)
        enable
        configure terminal
        router demo
        version 1
        exit
        commit
        show running-config
        exit
      SCRIPT
      expect(out).to include("Commit complete.")
      expect(out).to include("router demo")
      expect(out).to include("version 1")
    end

    it "deep-edit with commit from inside config-block returns to privileged" do
      _, out, _ = drive(<<~SCRIPT, session: Prouterd::Shell::Session.new)
        enable
        configure terminal
        router r
        exit
        process p
        block a
        image alpine:latest
        output result
        commit
        show processes
        exit
      SCRIPT
      expect(out).to include("Commit complete.")
      expect(out).to include("p")
    end

    it "abort discards candidate and returns to privileged" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        process lead_pipeline
        no block notify_sales
        abort
        show process lead_pipeline
        exit
      SCRIPT
      expect(out).to include("Candidate discarded.")
      expect(out).to include("notify_sales") # block restored after abort
    end

    it "commit failure stays in config mode for fixing" do
      _, out, _ = drive(<<~SCRIPT, session: Prouterd::Shell::Session.new)
        enable
        configure terminal
        router r
        exit
        process p
        commit
        block a
        image alpine
        output result
        commit
        exit
      SCRIPT
      expect(out).to include("Commit failed: 1 error(s)")
      expect(out).to include("has no blocks")
      expect(out.scan(/Commit complete/).length).to eq(1)
    end

    it "no command removes a process (and the user must clean up dependent routes)" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        no process lead_pipeline
        no route interface leads_in process lead_pipeline
        commit
        show processes
        exit
      SCRIPT
      expect(out).to include("Commit complete.")
      expect(out).to include("No processes defined.")
    end

    it "removing a process without removing dependent routes fails commit" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        no process lead_pipeline
        commit
        abort
        exit
      SCRIPT
      expect(out).to include("Commit failed")
      expect(out).to include("unknown process 'lead_pipeline'")
    end

    it "no command removes a global route" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        no route interface leads_in process lead_pipeline
        commit
        show running-config
        exit
      SCRIPT
      expect(out).to include("Commit complete.")
      expect(out).not_to include("route interface leads_in process lead_pipeline")
    end

    it "rejects exit from (config) mode without commit/abort" do
      _, _out, err = drive(<<~SCRIPT, session: Prouterd::Shell::Session.new)
        enable
        configure terminal
        exit
        abort
        exit
      SCRIPT
      expect(err).to include("uncommitted candidate changes")
    end
  end

  describe "show diff" do
    it "is empty when no changes" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        show diff
        abort
        exit
      SCRIPT
      expect(out).to include("No changes.")
    end

    it "highlights additions and deletions" do
      _, out, _ = drive(<<~SCRIPT, session: loaded_session)
        enable
        configure terminal
        process lead_pipeline
        no block notify_sales
        show diff
        abort
        exit
      SCRIPT
      # Removed lines start with "- "
      expect(out).to match(/^- /)
    end
  end

  describe "error reporting" do
    it "reports unknown command without crashing" do
      _, _out, err = drive("frobnicate\nexit\n")
      expect(err).to include("unknown command 'frobnicate'")
    end

    it "field validation errors stay in mode" do
      _, _out, err = drive(<<~SCRIPT, session: Prouterd::Shell::Session.new)
        enable
        configure terminal
        router r
        version notanumber
        exit
        abort
        exit
      SCRIPT
      expect(err).to include("expected integer for version")
    end
  end

  describe "execute_one (used by `prouter exec`)" do
    it "runs a single show against a session" do
      session = loaded_session
      shell = described_class.new(
        session: session,
        input: StringIO.new,
        output: (out = StringIO.new),
        error: StringIO.new,
        interactive: false,
        banner: false
      )
      shell.execute_one("show processes")
      expect(out.string).to include("lead_pipeline")
    end
  end
end
