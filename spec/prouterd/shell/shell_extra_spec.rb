require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe Prouterd::Shell::Shell do
  def session_with_running
    doc = Prouterd::Config::Parser.parse(
      Prouterd::Config::Lexer.tokenize(read_fixture("sales_ops.prc"))
    )
    Prouterd::Shell::Session.new(running_config: doc)
  end

  def build(input_str: "", session: Prouterd::Shell::Session.new, interactive: false, banner: false)
    described_class.new(
      session: session,
      input: StringIO.new(input_str),
      output: (@_out = StringIO.new),
      error: (@_err = StringIO.new),
      interactive: interactive,
      banner: banner
    )
  end

  describe ".run banner + interactive prompt + initial-config" do
    it "prints the banner when banner + interactive are set and stdin is a tty" do
      output = StringIO.new
      input = StringIO.new("exit\n")
      def input.isatty; true; end
      described_class.run(input: input, output: output, error: StringIO.new, banner: true)
      expect(output.string).to include("prouter")
      expect(output.string).to include("type 'help'")
    end

    it "loads initial config from a path before starting the loop" do
      Tempfile.create(["mini", ".prc"]) do |tmp|
        tmp.write(read_fixture("minimal.prc"))
        tmp.flush
        out = StringIO.new
        described_class.run(
          input: StringIO.new("enable\nshow running-config\nexit\n"),
          output: out,
          error: StringIO.new,
          interactive: false,
          banner: false,
          initial_config_path: tmp.path
        )
        expect(out.string).to include("router demo")
      end
    end

    it "raises ShellError when initial config path is missing" do
      expect {
        described_class.run(
          input: StringIO.new("exit\n"),
          output: StringIO.new,
          error: StringIO.new,
          interactive: false,
          banner: false,
          initial_config_path: "/no/such/file.prc"
        )
      }.to raise_error(Prouterd::Shell::ShellError, /not found/)
    end

    it "raises ShellError when initial config fails validation" do
      Tempfile.create(["bad", ".prc"]) do |tmp|
        tmp.write("router x\nexit\nprocess p\nexit\n")
        tmp.flush
        expect {
          described_class.run(
            input: StringIO.new("exit\n"),
            output: StringIO.new,
            error: (err = StringIO.new),
            interactive: false,
            banner: false,
            initial_config_path: tmp.path
          )
        }.to raise_error(Prouterd::Shell::ShellError, /initial config invalid/)
      end
    end
  end

  describe "#run loop behaviour" do
    it "ignores empty lines and continues" do
      shell = build(input_str: "\n   \nshow version\nexit\n")
      code = shell.run
      expect(code).to eq(0)
      expect(@_out.string).to include("prouter")
    end

    it "returns non-zero when a command raises CommandError in non-interactive mode" do
      shell = build(input_str: "frobnicate\nexit\n", interactive: false)
      expect(shell.run).to eq(1)
      expect(@_err.string).to include("unknown command")
    end

    it "swallows CommandError without changing exit code in interactive mode" do
      input = StringIO.new("frobnicate\nexit\n")
      def input.isatty; true; end
      shell = described_class.new(
        session: Prouterd::Shell::Session.new,
        input: input,
        output: StringIO.new,
        error: (err = StringIO.new),
        interactive: true,
        banner: false
      )
      allow(shell).to receive(:reline_available?).and_return(false)
      expect(shell.run).to eq(0)
      expect(err.string).to include("unknown command")
    end

    it "terminates when mode_stack is empty after a command pops it" do
      shell = build(input_str: "exit\nshould-not-execute\n")
      shell.run
      expect(@_err.string).not_to include("unknown command 'should-not-execute'")
    end

    it "returns nil from tokenize for a comment-only line and skips it" do
      shell = build(input_str: "! just a comment\nshow version\nexit\n")
      shell.run
      expect(@_out.string).to include("prouter")
    end
  end

  describe "#execute_one" do
    it "auto-pushes Privileged when stack is empty" do
      shell = build
      shell.execute_one("show version")
      expect(@_out.string).to include("prouter")
    end

    it "returns 0 on a comment-only line (tokenize returns nil)" do
      shell = build
      expect(shell.execute_one("! just a comment")).to eq(0)
    end

    it "returns 1 on CommandError" do
      shell = build
      expect(shell.execute_one("frobnicate")).to eq(1)
      expect(@_err.string).to include("unknown command")
    end

    it "handles a result hash that pushes a new mode" do
      shell = build
      # 'enable' returns {signal: :enter, mode: Privileged}
      shell.execute_one("enable")
    end
  end

  describe "#handle_result" do
    let(:shell) { build }

    it "pops one mode on :exit" do
      shell.instance_variable_get(:@session).mode_stack << Prouterd::Shell::Modes::User.new
      shell.instance_variable_get(:@session).mode_stack << Prouterd::Shell::Modes::Privileged.new
      shell.send(:handle_result, :exit)
      expect(shell.instance_variable_get(:@session).mode_stack.last).to be_a(Prouterd::Shell::Modes::User)
    end

    it "clears the stack on :quit" do
      session = shell.instance_variable_get(:@session)
      session.mode_stack << Prouterd::Shell::Modes::User.new
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      shell.send(:handle_result, :quit)
      expect(session.mode_stack).to be_empty
    end

    it "pops back to Privileged on :end" do
      session = shell.instance_variable_get(:@session)
      session.mode_stack << Prouterd::Shell::Modes::User.new
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell.send(:handle_result, :end)
      expect(session.mode_stack.last).to be_a(Prouterd::Shell::Modes::Privileged)
    end

    it "pushes a new mode for {signal: :enter, mode:}" do
      session = shell.instance_variable_get(:@session)
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell.send(:handle_result, { signal: :enter, mode: Prouterd::Shell::Modes::Privileged.new })
      expect(session.mode_stack.last).to be_a(Prouterd::Shell::Modes::Privileged)
    end

    it "raises ShellError for an unknown hash signal" do
      expect {
        shell.send(:handle_result, { signal: :other })
      }.to raise_error(Prouterd::Shell::ShellError, /unexpected mode result/)
    end

    it "raises ShellError for a totally unexpected return value" do
      expect {
        shell.send(:handle_result, :totally_unknown)
      }.to raise_error(Prouterd::Shell::ShellError, /unexpected mode result/)
    end
  end

  describe ":commit / :abort / :end" do
    let(:fake_running_session) do
      Class.new(Prouterd::Shell::Session) do
        attr_accessor :commit_result
        attr_reader :abort_called
        def commit_candidate
          @commit_result
        end
        def abort_candidate
          @abort_called = true
        end
      end
    end

    let(:commit_result) { Struct.new(:valid?, :warnings, :errors, keyword_init: true) }

    it ":commit on a valid candidate prints success and pops modes back to Privileged" do
      session = fake_running_session.new
      session.commit_result = commit_result.new(valid?: true, warnings: [], errors: [])
      shell = build(session: session)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell.send(:handle_result, :commit)
      expect(@_out.string).to include("Commit complete.")
      expect(session.mode_stack.last).to be_a(Prouterd::Shell::Modes::Privileged)
    end

    it ":commit prints warnings when valid" do
      session = fake_running_session.new
      session.commit_result = commit_result.new(valid?: true, warnings: ["w1", "w2"], errors: [])
      shell = build(session: session)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      shell.send(:handle_result, :commit)
      expect(@_out.string).to include("Warnings:")
      expect(@_out.string).to include("w1")
      expect(@_out.string).to include("w2")
    end

    it ":commit lists errors and leaves the stack alone when invalid" do
      session = fake_running_session.new
      session.commit_result = commit_result.new(valid?: false, warnings: [], errors: ["e1", "e2"])
      shell = build(session: session)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell.send(:handle_result, :commit)
      expect(@_out.string).to include("Commit failed: 2 error")
      expect(@_out.string).to include("e1")
      expect(session.mode_stack.last).to be_a(Prouterd::Shell::Modes::User)
    end

    it ":abort discards the candidate and pops back to Privileged" do
      session = fake_running_session.new
      shell = build(session: session)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      session.mode_stack << Prouterd::Shell::Modes::User.new
      shell.send(:handle_result, :abort)
      expect(session.abort_called).to be(true)
      expect(@_out.string).to include("Candidate discarded.")
      expect(session.mode_stack.last).to be_a(Prouterd::Shell::Modes::Privileged)
    end
  end

  describe "interactive prompt fallback (no Reline)" do
    it "prints the prompt to @output when interactive and reline missing" do
      input = StringIO.new("exit\n")
      def input.isatty; true; end
      output = StringIO.new
      shell = described_class.new(
        session: Prouterd::Shell::Session.new,
        input: input,
        output: output,
        error: StringIO.new,
        interactive: true,
        banner: false
      )
      allow(shell).to receive(:reline_available?).and_return(false)
      shell.run
      expect(output.string).to include("process-router>")
    end
  end

  describe "#reline_available?" do
    it "memoises the answer" do
      shell = build
      shell.instance_variable_set(:@reline_available, false)
      expect(Kernel).not_to receive(:require)
      expect(shell.send(:reline_available?)).to be(false)
    end

    it "returns false when require raises LoadError" do
      shell = build
      shell.instance_variable_set(:@reline_available, nil)
      allow(shell).to receive(:require).with("reline").and_raise(LoadError)
      expect(shell.send(:reline_available?)).to be(false)
    end
  end

  describe "run loop swallows Config::ConfigError" do
    it "writes the error to @error and continues" do
      bad_mode = Class.new(Prouterd::Shell::Modes::User) {
        def commands; super.merge("boom" => :cmd_boom); end
        def cmd_boom(*)
          raise Prouterd::Config::ConfigError.new("explicit config error", line: 5)
        end
      }
      input = StringIO.new("boom\nexit\n")
      output = StringIO.new
      error = StringIO.new
      session = Prouterd::Shell::Session.new
      session.mode_stack << bad_mode.new
      shell = described_class.new(
        session: session, input: input, output: output, error: error,
        interactive: false, banner: false
      )
      expect(shell.run).to eq(1)
      expect(error.string).to include("explicit config error")
    end
  end

  describe "#install_completer" do
    it "wires Reline#completion_proc to a lambda that delegates to Completer#call" do
      session = Prouterd::Shell::Session.new
      shell = described_class.new(
        session: session,
        input: StringIO.new, output: StringIO.new, error: StringIO.new,
        interactive: true, banner: false
      )
      reline = Module.new
      captured = nil
      reline.define_singleton_method(:completion_proc=) { |proc| captured = proc }
      reline.define_singleton_method(:line_buffer) { "show ver" }
      reline.define_singleton_method(:respond_to?) do |sym|
        %i[completion_proc= line_buffer].include?(sym)
      end
      stub_const("Reline", reline)
      shell.send(:install_completer)
      session.mode_stack << Prouterd::Shell::Modes::Privileged.new
      result = captured.call("ver")
      expect(result).to include("version")
    end

    it "rescues StandardError from Reline configuration and only warns once" do
      shell = build(interactive: true)
      reline = Module.new
      reline.define_singleton_method(:completion_proc=) { |_| raise StandardError, "boom" }
      reline.define_singleton_method(:respond_to?) { |_| false }
      stub_const("Reline", reline)
      shell.send(:install_completer)
      shell.send(:install_completer) # second call must be a no-op
      expect(@_err.string).to include("tab completion not installed")
      expect(@_err.string.scan(/tab completion not installed/).size).to eq(1)
    end
  end
end
