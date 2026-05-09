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
      expect(out).to include("extract  docker extractor")
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

  describe "error reporting" do
    it "reports unknown command without crashing" do
      _, _out, err = drive("frobnicate\nexit\n")
      expect(err).to include("unknown command 'frobnicate'")
    end
  end

  describe "execute_one" do
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
