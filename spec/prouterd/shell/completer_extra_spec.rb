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
      interface manual cli
       no shutdown
      exit
      interface docker img1
       image alpine
      exit
      process p
       block a
        interface docker img1
       exit
       block b
        interface docker img1
       exit
       route a b
      exit
    PRC
  end

  before do
    store.commit(document)
    session.mode_stack << Prouterd::Shell::Modes::Privileged.new
  end

  it "returns [] when mode_stack is empty" do
    session.mode_stack.clear
    expect(completer.call("", "")).to eq([])
  end

  it "returns [] for an unknown head command" do
    expect(completer.call("", "frobnicate ")).to eq([])
  end

  describe "show <target> arg drills" do
    it "completes 'show interface ' to interface names" do
      expect(completer.call("", "show interface ")).to include("cli", "img1")
    end

    it "completes 'show queue ' to queue names" do
      expect(completer.call("", "show queue ")).to eq([])
    end

    it "completes 'show block ' literally with 'process'" do
      expect(completer.call("", "show block ")).to eq(["process"])
    end

    it "completes 'show block process ' with process names" do
      expect(completer.call("", "show block process ")).to include("p")
    end

    it "completes 'show block process p ' with blocks of p" do
      expect(completer.call("", "show block process p ")).to contain_exactly("a", "b")
    end

    it "completes 'show logs ' literally with 'run'" do
      expect(completer.call("", "show logs ")).to eq(["run"])
    end

    it "completes 'show logs run ' with recent run uids" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      uids = completer.call("", "show logs run ")
      expect(uids).to include(r.uid)
    end

    it "completes 'show logs run <uid> ' with 'block'" do
      expect(completer.call("", "show logs run abc ")).to eq(["block"])
    end

    it "completes 'show logs run <uid> block ' with the run's step block_names" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      runs.create_step(run_id: r.id, block_name: "a")
      runs.create_step(run_id: r.id, block_name: "b")
      result = completer.call("", "show logs run #{r.uid} block ")
      expect(result).to contain_exactly("a", "b")
    end

    it "completes 'show routes ' literally with 'process'" do
      expect(completer.call("", "show routes ")).to eq(["process"])
    end

    it "completes 'show routes process ' with process names" do
      expect(completer.call("", "show routes process ")).to include("p")
    end

    it "completes 'show commit ' with commit ids" do
      ids = completer.call("", "show commit ")
      expect(ids).not_to be_empty
    end

    it "completes 'show dead-letter ' with 'run'" do
      expect(completer.call("", "show dead-letter ")).to eq(["run"])
    end

    it "completes 'show dead-letter run ' with recent run uids" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect(completer.call("", "show dead-letter run ")).not_to be_empty
    end

    it "completes 'show artifacts ' with 'run'" do
      expect(completer.call("", "show artifacts ")).to eq(["run"])
    end

    it "returns [] for 'show blocks process' (already drilled)" do
      expect(completer.call("", "show blocks process ")).to eq([])
    end

    it "returns [] for unknown 'show foo'" do
      expect(completer.call("", "show foo bar ")).to eq([])
    end
  end

  describe "replay" do
    it "completes 'replay ' with 'run'" do
      expect(completer.call("", "replay ")).to eq(["run"])
    end

    it "completes 'replay run ' with recent run uids" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect(completer.call("", "replay run ")).to include(r.uid)
    end

    it "completes 'replay run <uid> ' with 'from'" do
      expect(completer.call("", "replay run abc ")).to eq(["from"])
    end

    it "completes 'replay run <uid> from ' with the run's block names" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      runs.create_step(run_id: r.id, block_name: "a")
      expect(completer.call("", "replay run #{r.uid} from ")).to include("a")
    end

    it "returns [] when replay arg count is too high" do
      expect(completer.call("", "replay run abc from a extra ")).to eq([])
    end
  end

  describe "cancel" do
    it "completes 'cancel ' with 'run'" do
      expect(completer.call("", "cancel ")).to eq(["run"])
    end

    it "completes 'cancel run ' with recent run uids" do
      runs = Prouterd::Storage::Repositories::Runs.new(db)
      r = runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil)
      expect(completer.call("", "cancel run ")).to include(r.uid)
    end

    it "returns [] for tokens beyond cancel run <uid>" do
      expect(completer.call("", "cancel run abc x ")).to eq([])
    end
  end

  describe "rollback" do
    it "completes 'rollback ' with 'commit'" do
      expect(completer.call("", "rollback ")).to eq(["commit"])
    end

    it "completes 'rollback commit ' with commit ids" do
      expect(completer.call("", "rollback commit ")).not_to be_empty
    end

    it "returns [] for tokens beyond rollback commit <id>" do
      expect(completer.call("", "rollback commit 1 x ")).to eq([])
    end
  end

  describe "write" do
    it "completes 'write ' with 'memory'" do
      expect(completer.call("", "write ")).to eq(["memory"])
    end

    it "returns [] for tokens beyond 'write memory'" do
      expect(completer.call("", "write memory x ")).to eq([])
    end
  end

  describe "copy" do
    it "completes 'copy ' with 'running-config'" do
      expect(completer.call("", "copy ")).to eq(["running-config"])
    end

    it "completes 'copy running-config ' with 'startup-config'" do
      expect(completer.call("", "copy running-config ")).to eq(["startup-config"])
    end

    it "returns [] beyond two args" do
      expect(completer.call("", "copy a b ")).to eq([])
    end
  end

  describe "trigger" do
    it "returns [] beyond 'trigger process X input'" do
      expect(completer.call("", "trigger process p input event ")).to eq([])
    end

    it "completes 'trigger process p ' with 'input'" do
      expect(completer.call("", "trigger process p ")).to eq(["input"])
    end
  end

  describe "prc files" do
    it "completes 'apply ' / 'load ' / 'diff ' / 'check ' with .prc files in cwd or examples/" do
      Dir.mktmpdir do |tmp|
        Dir.chdir(tmp) do
          File.write("sample.prc", "x")
          %w[apply load diff check].each do |head|
            result = completer.call("", "#{head} ")
            expect(result).to include("sample.prc")
          end
        end
      end
    end

    it "returns [] beyond a single arg for prc-file commands" do
      expect(completer.call("", "apply file1 file2 ")).to eq([])
    end
  end

  describe "recent_run_uids degrades gracefully" do
    it "returns [] when there is no store" do
      bare = Prouterd::Shell::Session.new(store: nil)
      bare.mode_stack << Prouterd::Shell::Modes::Privileged.new
      c = described_class.new(bare)
      expect(c.call("", "show run ")).to eq([])
    end

    it "returns [] when a DB query raises" do
      runs_repo_double = double
      allow(runs_repo_double).to receive(:list_runs).and_raise(StandardError, "boom")
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(runs_repo_double)
      expect(completer.call("", "show run ")).to eq([])
    end
  end

  describe "blocks_for_replay degrades gracefully" do
    it "returns [] when run lookup fails" do
      runs_repo_double = double
      allow(runs_repo_double).to receive(:get_run_by_uid).and_raise(StandardError, "boom")
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(runs_repo_double)
      expect(completer.call("", "replay run someuid from ")).to eq([])
    end

    it "returns [] when no run exists by that uid" do
      expect(completer.call("", "replay run no-such-uid from ")).to eq([])
    end
  end

  describe "blocks_in_process_of_run degrades gracefully" do
    it "returns [] when run lookup raises" do
      runs_repo_double = double
      allow(runs_repo_double).to receive(:get_run_by_uid).and_raise(StandardError, "boom")
      allow(Prouterd::Storage::Repositories::Runs).to receive(:new).and_return(runs_repo_double)
      expect(completer.call("", "show logs run someuid block ")).to eq([])
    end

    it "returns [] when no run exists by that uid" do
      expect(completer.call("", "show logs run no-such-uid block ")).to eq([])
    end
  end

  describe "commit_ids degrades gracefully" do
    it "returns [] when there is no store" do
      bare = Prouterd::Shell::Session.new(store: nil)
      bare.mode_stack << Prouterd::Shell::Modes::Privileged.new
      c = described_class.new(bare)
      expect(c.call("", "show commit ")).to eq([])
    end

    it "returns [] when commits query raises" do
      allow(store).to receive(:list_commits).and_raise(StandardError, "boom")
      expect(completer.call("", "show commit ")).to eq([])
    end
  end

  describe "prc_files degrades gracefully" do
    it "returns [] when Dir.glob raises" do
      allow(Dir).to receive(:glob).and_raise(StandardError, "boom")
      expect(completer.call("", "apply ")).to eq([])
    end
  end

  describe "blocks_in_process returns [] for unknown process" do
    it "completes empty list for show block process <unknown>" do
      expect(completer.call("", "show block process unknown ")).to eq([])
    end
  end
end
