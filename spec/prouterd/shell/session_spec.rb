require "spec_helper"

RSpec.describe Prouterd::Shell::Session do
  it "starts with empty running config and no candidate" do
    s = described_class.new
    expect(s.running_config).to be_a(Prouterd::Config::AST::Document)
    expect(s.in_config_mode?).to be(false)
    expect(s.candidate_config).to be_nil
  end

  it "uses default hostname when no router is set" do
    expect(described_class.new.hostname).to eq("process-router")
  end

  it "uses router hostname when configured" do
    doc = Prouterd::Config::AST::Document.new
    doc.router = Prouterd::Config::AST::Router.new(name: "x", line: 0)
    doc.router.hostname = "myrouter-1"
    s = described_class.new(running_config: doc)
    expect(s.hostname).to eq("myrouter-1")
  end

  describe "candidate flow" do
    let(:running_doc) do
      Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(read_fixture("sales_ops.prc"))
      )
    end

    let(:session) { described_class.new(running_config: running_doc) }

    it "begin_candidate clones running" do
      session.begin_candidate
      expect(session.in_config_mode?).to be(true)
      expect(session.candidate_config).not_to be_nil
      expect(session.candidate_config).not_to equal(session.running_config)
      expect(session.candidate_config.processes.length).to eq(running_doc.processes.length)
    end

    it "candidate edits do not affect running" do
      session.begin_candidate
      session.candidate_config.processes.first.description = "modified"
      expect(session.running_config.processes.first.description).to eq("Lead enrichment and sales notification")
    end

    it "commit_candidate swaps candidate into running on success" do
      session.begin_candidate
      session.candidate_config.processes.first.description = "modified"
      result = session.commit_candidate
      expect(result.valid?).to be(true)
      expect(session.running_config.processes.first.description).to eq("modified")
      expect(session.in_config_mode?).to be(false)
    end

    it "commit_candidate returns failure result without swapping on validation error" do
      session.begin_candidate
      session.candidate_config.processes.first.blocks.clear
      result = session.commit_candidate
      expect(result.valid?).to be(false)
      # Running unchanged:
      expect(session.running_config.processes.first.blocks).not_to be_empty
      # Candidate still around so user can fix:
      expect(session.in_config_mode?).to be(true)
    end

    it "abort_candidate discards candidate" do
      session.begin_candidate
      session.candidate_config.processes.first.description = "modified"
      session.abort_candidate
      expect(session.in_config_mode?).to be(false)
      expect(session.running_config.processes.first.description).to eq("Lead enrichment and sales notification")
    end

    it "begin_candidate raises if already in config mode" do
      session.begin_candidate
      expect { session.begin_candidate }.to raise_error(Prouterd::Shell::ShellError, /already in config/)
    end

    it "replace_running rejects in config mode" do
      session.begin_candidate
      expect { session.replace_running(running_doc) }.to raise_error(Prouterd::Shell::ShellError, /commit or abort first/)
    end
  end
end
