require "spec_helper"

RSpec.describe Prouterd::Shell::Completer do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:session) { Prouterd::Shell::Session.new(store: store) }
  let(:completer) { described_class.new(session) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      secret API_KEY
       source env API_KEY
      exit
      policy r3
       retry attempts 3
       retry backoff fixed
      exit
      queue default
       concurrency 1
       timeout 1m
      exit
      interface manual cli
       no shutdown
      exit
      interface docker img1
       image alpine
      exit
      process lead_pipeline
       block extract
        interface docker img1
       exit
       block enrich
        interface docker img1
       exit
      exit
      process billing
       block compute
        interface docker img1
       exit
      exit
    PRC
  end

  before do
    store.commit(document)
    session.mode_stack << Prouterd::Shell::Modes::Privileged.new
  end

  describe "in privileged mode" do
    it "completes empty input to the full command list" do
      result = completer.call("", "")
      expect(result).to include("show", "trigger", "replay", "exit")
    end

    it "expands a unique prefix" do
      expect(completer.call("sh", "sh")).to eq(["show"])
      expect(completer.call("rep", "rep")).to eq(["replay"])
    end

    it "lists matching commands for ambiguous prefix" do
      result = completer.call("c", "c")
      expect(result).to include("cancel", "copy")
    end
  end

  describe "show <target>" do
    it "lists top-level show targets after `show `" do
      result = completer.call("", "show ")
      expect(result).to include("running-config", "processes", "process", "runs", "logs", "commits")
    end

    it "filters show targets by prefix" do
      result = completer.call("pr", "show pr")
      expect(result).to eq(["process", "processes"])
    end

    it "lists process names after `show process `" do
      result = completer.call("", "show process ")
      expect(result).to contain_exactly("lead_pipeline", "billing")
    end

    it "filters process names by prefix" do
      result = completer.call("lead", "show process lead")
      expect(result).to eq(["lead_pipeline"])
    end

    it "lists policy names after `show policy `" do
      result = completer.call("", "show policy ")
      expect(result).to eq(["r3"])
    end

    it "lists secret names after `show secret `" do
      result = completer.call("", "show secret ")
      expect(result).to eq(["API_KEY"])
    end

    it "drills down: `show block process X ` lists blocks of X" do
      result = completer.call("", "show block process lead_pipeline ")
      expect(result).to contain_exactly("extract", "enrich")
    end
  end

  describe "trigger / replay / cancel" do
    it "trigger completes 'process'" do
      expect(completer.call("", "trigger ")).to eq(["process"])
    end

    it "trigger process <Tab> lists process names" do
      result = completer.call("", "trigger process ")
      expect(result).to include("lead_pipeline", "billing")
    end

    it "replay completes 'run'" do
      expect(completer.call("", "replay ")).to eq(["run"])
    end

    it "rollback completes 'commit' then commit ids" do
      expect(completer.call("", "rollback ")).to eq(["commit"])
      ids = completer.call("", "rollback commit ")
      expect(ids).to include("1") # the test config commit
    end
  end

  describe "in user mode" do
    before do
      session.mode_stack.clear
      session.mode_stack << Prouterd::Shell::Modes::User.new
    end

    it "shows only user-mode commands" do
      result = completer.call("", "")
      expect(result).to include("enable", "show", "exit")
      expect(result).not_to include("rollback")
    end
  end
end
