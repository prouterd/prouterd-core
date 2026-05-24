require "spec_helper"
require "ostruct"

# Covers Session#replay_from edge cases the main replay flow doesn't
# hit: the chosen block existed in the original run but its step row
# was persisted without input_json (e.g. crashed pre-launch, or an
# older code path that didn't capture inputs).
RSpec.describe Prouterd::Shell::Session do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:session) { described_class.new(store: store, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface docker img
       image x
      exit
      process p
       block a
        interface docker img
       exit
       block b
        interface docker img
       exit
       route a b
      exit
    PRC
  end

  before { store.commit(document) }

  describe "#orchestrator construction guards" do
    it "raises ShellError when no store is attached" do
      bare = described_class.new(store: nil, runner: runner)
      expect { bare.orchestrator }.to raise_error(Prouterd::Shell::ShellError, /no DB attached/)
    end

    it "raises ShellError when no runner is configured" do
      no_runner = described_class.new(store: store, runner: nil)
      expect { no_runner.orchestrator }.to raise_error(Prouterd::Shell::ShellError, /no runner configured/)
    end
  end

  describe "rollback / write_memory store guards" do
    it "rollback_to raises ShellError when no store is attached" do
      bare = described_class.new(store: nil)
      expect { bare.rollback_to(1) }.to raise_error(Prouterd::Shell::ShellError, /requires a config store/)
    end

    it "write_memory raises ShellError when no store is attached" do
      bare = described_class.new(store: nil)
      expect { bare.write_memory }.to raise_error(Prouterd::Shell::ShellError, /requires a config store/)
    end
  end

  describe "replay store guards" do
    it "replay raises ShellError when no store is attached" do
      bare = described_class.new(store: nil, runner: runner)
      expect { bare.replay("anything") }.to raise_error(Prouterd::Shell::ShellError, /requires --db/)
    end
  end

  describe "replay event payload assembly" do
    before { store.commit(document) }

    it "feeds JSON-parsed input_event_json into the replay when present" do
      original = session.orchestrator.trigger(document, "p",
                                               input_event: { "k" => "v" },
                                               commit_id: store.running_commit.id)
      expect(session.orchestrator).to receive(:trigger) do |_doc, _name, **kwargs|
        expect(kwargs[:input_event]).to eq("k" => "v")
        OpenStruct.new(id: 99, uid: "run_replay", status: "success")
      end
      session.replay(original.uid)
    end

    it "passes {} as input_event when the original run carried no input_event_json" do
      original = session.orchestrator.trigger(document, "p",
                                               input_event: {},
                                               commit_id: store.running_commit.id)
      db.execute("UPDATE runs SET input_event_json = NULL WHERE id = ?", [original.id])
      expect(session.orchestrator).to receive(:trigger) do |_doc, _name, **kwargs|
        expect(kwargs[:input_event]).to eq({})
        OpenStruct.new(id: 99, uid: "run_replay", status: "success")
      end
      session.replay(original.uid)
    end

    it "raises ShellError when the original run's pinned commit is gone" do
      original = session.orchestrator.trigger(document, "p",
                                               input_event: {},
                                               commit_id: store.running_commit.id)
      commit_id = store.running_commit.id
      db.execute("PRAGMA foreign_keys = OFF")
      db.execute("DELETE FROM config_commits WHERE id = ?", [commit_id])
      db.execute("PRAGMA foreign_keys = ON")
      expect {
        session.replay(original.uid)
      }.to raise_error(Prouterd::Shell::ShellError, /no longer exists/)
    end
  end

  it "raises ShellError when the chosen step row has no captured input_json" do
    # Run the process so we get a real run + steps, then null out the
    # input_json on the step we want to replay from.
    original = session.orchestrator.trigger(document, "p",
                                             input_event: { "k" => "v" },
                                             commit_id: store.running_commit.id)
    step = repo.list_steps(original.id).find { |s| s.block_name == "b" }
    expect(step.input_json).not_to be_nil
    db.execute("UPDATE run_steps SET input_json = NULL WHERE id = ?", [step.id])

    expect {
      session.replay_from(original.uid, "b")
    }.to raise_error(Prouterd::Shell::ShellError, /no captured input/)
  end
end
