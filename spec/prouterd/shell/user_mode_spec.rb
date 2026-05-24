require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Shell::Modes::User do
  let(:session) { Prouterd::Shell::Session.new }
  let(:out)     { StringIO.new }
  let(:err)     { StringIO.new }
  let(:mode)    { described_class.new }

  def tokens_for(line)
    Prouterd::Shell::CommandLine.tokenize(line)
  end

  describe "#cmd_help" do
    it "prints user-mode help and returns :handled" do
      result = mode.execute(tokens_for("help"), session, out, err)
      expect(result).to eq(:handled)
      expect(out.string).to include("User mode commands:")
      expect(out.string).to include("enable")
      expect(out.string).to include("show version")
      expect(out.string).to include("exit, logout, quit")
    end

    it "is reachable via `?`" do
      result = mode.execute(tokens_for("?"), session, out, err)
      expect(result).to eq(:handled)
      expect(out.string).to include("User mode commands:")
    end
  end

  describe "#cmd_enable" do
    it "returns an :enter signal with Privileged" do
      result = mode.execute(tokens_for("enable"), session, out, err)
      expect(result).to be_a(Hash)
      expect(result[:signal]).to eq(:enter)
      expect(result[:mode]).to be_a(Prouterd::Shell::Modes::Privileged)
    end
  end

  describe "#cmd_show" do
    it "raises CommandError when no target is given (target nil branch)" do
      expect {
        mode.execute(tokens_for("show"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /show <missing>/)
    end

    it "raises CommandError on a non-allowed target" do
      expect {
        mode.execute(tokens_for("show running-config"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /requires privileged mode/)
    end

    it "resolves an exact allowed target" do
      result = mode.execute(tokens_for("show version"), session, out, err)
      expect(result).to eq(:handled)
    end

    it "expands a unique prefix to an allowed target" do
      result = mode.execute(tokens_for("show ver"), session, out, err)
      expect(result).to eq(:handled)
    end
  end

  describe "#cmd_exit / logout / quit" do
    it "exit returns :quit" do
      expect(mode.execute(tokens_for("exit"), session, out, err)).to eq(:quit)
    end

    it "logout returns :quit" do
      expect(mode.execute(tokens_for("logout"), session, out, err)).to eq(:quit)
    end

    it "quit returns :quit" do
      expect(mode.execute(tokens_for("quit"), session, out, err)).to eq(:quit)
    end
  end

  describe "unknown command" do
    it "raises CommandError via apply_field" do
      expect {
        mode.execute(tokens_for("totally-unknown-thing"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /unknown command/)
    end
  end

  describe "#prompt_suffix" do
    it "returns >" do
      expect(mode.prompt_suffix).to eq(">")
    end
  end
end
