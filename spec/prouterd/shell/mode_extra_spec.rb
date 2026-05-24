require "spec_helper"
require "stringio"

RSpec.describe Prouterd::Shell::Mode do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:session) { Prouterd::Shell::Session.new(store: store) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:base) { described_class.new }

  after { db.close }

  def tokens(str)
    Prouterd::Shell::CommandLine.tokenize(str)
  end

  describe "abstract methods" do
    it "raises NotImplementedError on prompt_suffix" do
      expect { base.prompt_suffix }.to raise_error(NotImplementedError)
    end

    it "returns {} for commands by default" do
      expect(base.commands).to eq({})
    end

    it "renders help_lines as commands.keys.sort" do
      m = Class.new(described_class) {
        def commands; { "z" => :a, "a" => :b, "m" => :c }; end
      }.new
      expect(m.help_lines).to eq(["  a", "  m", "  z"])
    end
  end

  describe "#apply_field default behaviour" do
    it "raises CommandError with 'unknown command' for the base class" do
      expect {
        base.apply_field(tokens("frobnicate"), session)
      }.to raise_error(Prouterd::Shell::CommandError, /unknown command 'frobnicate'/)
    end
  end

  describe "#run_do" do
    it "raises syntax error when called without a command" do
      m = base
      expect {
        m.run_do(tokens("do"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: do/)
    end

    it "passes through to a Privileged command and returns :handled on success" do
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      session.replace_running(
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize("router demo\nexit\n"))
      )
      m = base
      result = m.run_do(tokens("do show version"), session, out, err)
      expect(result).to eq(:handled)
      expect(out.string).to include("prouter")
    end

    it "rejects a command that would change mode (Hash returned)" do
      m = base
      stub = Class.new(Prouterd::Shell::Modes::Privileged) {
        def cmd_enter_disable(*); { signal: :enter, mode: Prouterd::Shell::Modes::User.new }; end
        def commands
          super.merge("enter-disable" => :cmd_enter_disable)
        end
      }
      allow(Prouterd::Shell::Modes::Privileged).to receive(:new).and_return(stub.new)
      expect {
        m.run_do(tokens("do enter-disable"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /cannot run mode-changing/)
    end

    it "rejects a command whose dispatch returns :exit" do
      m = base
      stub = Class.new(Prouterd::Shell::Modes::Privileged) {
        def cmd_d(*); :exit; end
        def commands
          super.merge("d" => :cmd_d)
        end
      }
      allow(Prouterd::Shell::Modes::Privileged).to receive(:new).and_return(stub.new)
      expect {
        m.run_do(tokens("do d"), session, out, err)
      }.to raise_error(Prouterd::Shell::CommandError, /cannot run mode-changing/)
    end

    it "rejects a command whose dispatch returns :quit / :commit / :abort / :end" do
      %i[quit commit abort end].each do |sig|
        m = base
        stub = Class.new(Prouterd::Shell::Modes::Privileged) {
          define_method(:cmd_q) { |*| sig }
          define_method(:commands) { super().merge("q" => :cmd_q) }
        }
        allow(Prouterd::Shell::Modes::Privileged).to receive(:new).and_return(stub.new)
        expect {
          m.run_do(tokens("do q"), session, out, err)
        }.to raise_error(Prouterd::Shell::CommandError, /cannot run mode-changing/)
      end
    end

    it "returns :handled when dispatch returns an unexpected value" do
      m = base
      stub = Class.new(Prouterd::Shell::Modes::Privileged) {
        def cmd_x(*); :totally_unknown; end
        def commands
          super.merge("x" => :cmd_x)
        end
      }
      allow(Prouterd::Shell::Modes::Privileged).to receive(:new).and_return(stub.new)
      expect(m.run_do(tokens("do x"), session, out, err)).to eq(:handled)
    end
  end

  describe "#expect_arg_count / #expect_min_args" do
    it "expect_arg_count passes when match" do
      expect {
        base.send(:expect_arg_count, tokens("a b"), 2, "a b")
      }.not_to raise_error
    end

    it "expect_arg_count raises on mismatch" do
      expect {
        base.send(:expect_arg_count, tokens("a b"), 3, "a b c")
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: a b c/)
    end

    it "expect_min_args raises when too few" do
      expect {
        base.send(:expect_min_args, tokens("a"), 2, "a b")
      }.to raise_error(Prouterd::Shell::CommandError, /syntax: a b/)
    end
  end

  describe "#expand_prefix" do
    it "raises CommandError on ambiguous prefix" do
      expect {
        base.send(:expand_prefix, "co", ["copy", "config"])
      }.to raise_error(Prouterd::Shell::CommandError, /ambiguous command/)
    end

    it "returns the exact match in preference to a prefix superset" do
      expect(base.send(:expand_prefix, "do", ["do", "down"])).to eq("do")
    end

    it "returns nil when no match" do
      expect(base.send(:expand_prefix, "zz", ["copy", "config"])).to be_nil
    end

    it "returns the single prefix match" do
      expect(base.send(:expand_prefix, "co", ["copy"])).to eq("copy")
    end
  end

  describe "#execute trailing '?' context help" do
    it "lists candidate next-tokens via the Completer" do
      session.replace_running(
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize("router demo\nexit\n"))
      )
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      m = session.mode_stack.last
      m.execute(tokens("show ?"), session, out, err)
      # show targets get printed; one per line under '  '
      expect(out.string.lines.any? { |l| l.strip == "running-config" || l.strip == "processes" }).to be(true)
    end

    it "prints '<cr>' when no further input is expected" do
      session.replace_running(
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize("router demo\nexit\n"))
      )
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      m = session.mode_stack.last
      m.execute(tokens("show version ?"), session, out, err)
      expect(out.string).to include("<cr>")
    end
  end

  describe "#execute bare ?" do
    it "invokes help when commands include 'help'" do
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      m = session.mode_stack.last
      m.execute(tokens("?"), session, out, err)
      expect(out.string).to include("Privileged mode commands")
    end
  end

  describe "match_keyword?" do
    it "returns false for nil / empty actual" do
      expect(base.send(:match_keyword?, nil, "running-config")).to be(false)
      expect(base.send(:match_keyword?, "", "running-config")).to be(false)
    end

    it "returns true on exact match" do
      expect(base.send(:match_keyword?, "running-config", "running-config")).to be(true)
    end

    it "returns true on prefix match" do
      expect(base.send(:match_keyword?, "run", "running-config")).to be(true)
    end

    it "returns false on non-prefix" do
      expect(base.send(:match_keyword?, "running-z", "running-config")).to be(false)
    end
  end

  describe "#values" do
    it "returns the underlying token values" do
      expect(base.send(:values, tokens("a b c"))).to eq(["a", "b", "c"])
    end
  end

  describe "#enter" do
    it "returns a hash signal carrying the new mode" do
      m = Prouterd::Shell::Modes::User.new
      result = base.send(:enter, m)
      expect(result).to eq(signal: :enter, mode: m)
    end
  end
end
