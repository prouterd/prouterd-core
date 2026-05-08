require "spec_helper"
require "stringio"

RSpec.describe "Phase 18 router-CLI compatibility" do
  def drive(script, session: nil)
    input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
    output = StringIO.new
    error  = StringIO.new
    session ||= Prouterd::Shell::Session.new
    code = Prouterd::Shell::Shell.run(
      session: session,
      input: input,
      output: output,
      error: error,
      interactive: false,
      banner: false
    )
    [code, output.string, error.string]
  end

  describe "unique-prefix abbreviation in Mode#execute" do
    it "expands `sh ver` to `show version`" do
      _, out, err = drive("sh ver")
      expect(err).to be_empty
      expect(out).to include("prouter")
    end

    it "expands `enab` to `enable`" do
      _, _out, err = drive("enab")
      expect(err).to be_empty
    end

    it "expands `wr m` to `write memory` (and falls through to no-DB error)" do
      _, _out, err = drive("enable\nwr m")
      expect(err).to include("no DB attached")
    end

    it "raises ambiguous on `c` in privileged mode" do
      _, _out, err = drive("enable\nc")
      expect(err).to include("ambiguous command 'c'")
      expect(err).to include("cancel")
      expect(err).to include("configure")
      expect(err).to include("copy")
    end

    it "expands keyword arguments too: `conf t`" do
      # `conf t` enters config; `commit` (not `end`) promotes the candidate
      # so `sh run` afterwards reflects the new router section.
      _, out, err = drive("enable\nconf t\nrouter demo\nexit\ncommit\nsh run")
      expect(err).to be_empty
      expect(out).to include("router demo")
    end
  end

  describe "show subsystem prefix expansion" do
    it "uses plural for bare prefix matching singular+plural pair" do
      _, out, err = drive("enable\nsh int")
      expect(err).to be_empty
      expect(out).to include("No interfaces defined.")
    end

    it "uses singular when args are present" do
      _, _out, err = drive("enable\nsh int demo")
      expect(err).to include("no such interface 'demo'")
    end

    it "raises on truly ambiguous prefix that isn't a singular/plural pair" do
      _, _out, err = drive("enable\nsh log")
      expect(err).to include("ambiguous show target 'log'")
    end

    it "treats bare `show run` as `show running-config` (router-CLI habit)" do
      _, out, err = drive("enable\nsh run")
      expect(err).to be_empty
      expect(out).to include("(empty configuration)")
    end

    it "still treats `show run <uid>` as the prouter run-detail command" do
      # show_run prints the no-DB notice to stdout (it's a status, not an error).
      _, out, _err = drive("enable\nsh run nope-xxx")
      expect(out).to include("no DB attached")
    end
  end

  describe "router `end` command" do
    it "from a config sub-mode jumps straight back to privileged" do
      _, out, err = drive("enable\nconf t\nrouter demo\nend\nsh run")
      expect(err).to be_empty
      # Renderer ran, meaning we're back in privileged with the candidate
      # promoted to running... but `end` does NOT auto-commit, so the
      # router section should still be in the candidate, not the running.
      # Actually `end` keeps the candidate; running is unchanged.
      expect(out).to include("(empty configuration)")
    end

    it "from a deeply nested editor (config-block) also pops to privileged" do
      script = <<~SCRIPT
        enable
        conf t
        process p1
        block b1
        end
        sh run
      SCRIPT
      _, _out, err = drive(script)
      # We expect `end` to leave us in privileged so `sh run` works without
      # being interpreted as a block field.
      expect(err).not_to include("unknown command 'sh'")
    end
  end

  describe "router `do <command>` from config" do
    it "runs a privileged-mode command without leaving config" do
      _, out, err = drive("enable\nconf t\ndo sh ver\nabort")
      expect(err).to be_empty
      expect(out).to include("prouter")
      expect(out).to include("Candidate discarded")
    end

    it "rejects mode-changing commands" do
      # `do disable` would drop us to user mode if it weren't blocked.
      _, _out, err = drive("enable\nconf t\ndo disable\nabort")
      expect(err).to include("'do' cannot run mode-changing commands")
    end

    it "requires at least one argument" do
      _, _out, err = drive("enable\nconf t\ndo\nabort")
      expect(err).to include("syntax: do")
    end
  end

  describe "context-sensitive `?` mid-line" do
    it "lists candidate next tokens for `show ?`" do
      _, out, err = drive("enable\nshow ?")
      expect(err).to be_empty
      expect(out).to include("running-config")
      expect(out).to include("interfaces")
      expect(out).to include("clock")
    end

    it "prints `<cr>` when no further completion is expected" do
      _, out, err = drive("enable\nshow status ?")
      expect(err).to be_empty
      expect(out).to include("<cr>")
    end

    it "standalone `?` prints mode help" do
      _, out, _err = drive("enable\n?")
      expect(out).to include("Privileged mode commands")
    end
  end

  describe "`logout` and `quit` aliases" do
    it "logout from user mode quits the shell" do
      code, _out, err = drive("logout")
      expect(err).to be_empty
      expect(code).to eq(0)
    end

    it "quit from privileged mode quits the shell" do
      code, _out, err = drive("enable\nquit")
      expect(err).to be_empty
      expect(code).to eq(0)
    end
  end

  describe "`copy running-config startup-config`" do
    it "is an alias for `write memory` (errors with no DB the same way)" do
      _, _out, err = drive("enable\ncopy running-config startup-config")
      expect(err).to include("no DB attached")
    end

    it "rejects malformed copy invocations" do
      _, _out, err = drive("enable\ncopy something else")
      expect(err).to include("syntax: copy running-config startup-config")
    end

    it "abbreviates as `cop ru st`" do
      _, _out, err = drive("enable\ncop ru st")
      expect(err).to include("no DB attached")
    end
  end

  describe "router-iconic show targets" do
    it "show clock prints a UTC timestamp" do
      _, out, err = drive("enable\nshow clock")
      expect(err).to be_empty
      expect(out).to match(/\d{2}:\d{2}:\d{2}.*UTC/)
    end

    it "show logging prints the logging configuration" do
      _, out, err = drive("enable\nshow logging")
      expect(err).to be_empty
      expect(out).to include("Logging configuration:")
      expect(out).to include("PROUTERD_LOG_LEVEL")
    end

    it "show logging last N tails the in-memory ring buffer" do
      Prouterd::Logger.build(StringIO.new).info("greeting",
                                                facility: "TEST", mnemonic: "HELLO",
                                                user: "alice")
      _, out, err = drive("enable\nshow logging last 5")
      expect(err).to be_empty
      expect(out).to match(/%TEST-6-HELLO: greeting user=alice/)
    end

    it "show logging severity filters by level" do
      Prouterd::Logger.build(StringIO.new).debug("noisy",
                                                 facility: "TEST", mnemonic: "DBG")
      Prouterd::Logger.build(StringIO.new).error("loud",
                                                  facility: "TEST", mnemonic: "ERR")
      _, out, err = drive("enable\nshow logging last 50 severity 3")
      expect(err).to be_empty
      expect(out).to include("%TEST-3-ERR")
      expect(out).not_to include("%TEST-7-DBG")
    end

    it "show logging facility filters by facility name" do
      Prouterd::Logger.build(StringIO.new).info("a",
                                                facility: "ALPHA", mnemonic: "A")
      Prouterd::Logger.build(StringIO.new).info("b",
                                                facility: "BETA", mnemonic: "B")
      _, out, err = drive("enable\nshow logging last 50 facility alpha")
      expect(err).to be_empty
      expect(out).to include("%ALPHA-6-A")
      expect(out).not_to include("%BETA-6-B")
    end

    it "show logging rejects bad severity" do
      _, _, err = drive("enable\nshow logging last 10 severity 99")
      expect(err).to include("severity must be 0-7")
    end

    it "show history works (or politely declines without Reline)" do
      _, out, err = drive("enable\nshow history")
      expect(err).to be_empty
      expect(out).to match(/no history available|^\s*\d+/)
    end

    it "show clock is allowed in user mode (no enable required)" do
      _, out, err = drive("show clock")
      expect(err).to be_empty
      expect(out).to match(/UTC/)
    end
  end

  describe "multi-token `description` (router-style free-text)" do
    it "accepts an unquoted description in the parser" do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          process p1
           description This is a free text description
          exit
        PRC
      )
      expect(doc.processes.first.description).to eq("This is a free text description")
    end

    it "renderer re-quotes the description so roundtrip is idempotent" do
      src = <<~PRC
        process p1
         description This is unquoted
        exit
      PRC
      doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
      rendered = Prouterd::Config::Renderer.render(doc)
      expect(rendered).to include('description "This is unquoted"')

      doc2 = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(rendered))
      expect(doc2.processes.first.description).to eq("This is unquoted")
    end

    it "accepts a quoted description as before (back-compat)" do
      doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(<<~PRC)
          process p1
           description "Quoted description with spaces"
          exit
        PRC
      )
      expect(doc.processes.first.description).to eq("Quoted description with spaces")
    end

    it "raises if no description text follows" do
      expect {
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
          process p1
           description
          exit
        PRC
      }.to raise_error(Prouterd::Config::ParseError, /description requires text/)
    end
  end
end
