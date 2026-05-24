require "spec_helper"

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
