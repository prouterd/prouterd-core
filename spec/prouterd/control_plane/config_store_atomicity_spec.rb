require "spec_helper"

# Phase 34c regression spec.
#
# `ConfigStore#commit` writes two rows that MUST land or roll back
# together — the new commit row + the running-pointer flip. If we ever
# accidentally moved them out of the surrounding `@db.transaction do`
# block, a crash between the two writes would leave the daemon
# in a state where commit history advanced but no pointer references
# the new row (or the inverse). This spec pins the atomic behaviour.
RSpec.describe Prouterd::ControlPlane::ConfigStore do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { described_class.new(db) }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(
      Prouterd::Config::Lexer.tokenize(<<~PRC)
        router demo
        exit
        interface manual cli
         no shutdown
        exit
        interface shell host
        exit
        process p
         block a
          interface shell host
         exit
        exit
        route interface cli process p
        exit
      PRC
    )
  end

  it "rolls back the inserted commit row when set_pointer fails mid-transaction" do
    # Reach into the private repo so we can fail the second write only.
    repo = store.instance_variable_get(:@configs)
    boom = Class.new(StandardError)
    allow(repo).to receive(:set_pointer).and_raise(boom, "simulated mid-transaction failure")

    expect {
      store.commit(document, author: "a", message: "m")
    }.to raise_error(boom)

    # Both writes were in one transaction → the commit row must NOT
    # be visible after the rollback.
    expect(store.list_commits).to eq([])
    expect(store.commit_count).to eq(0)
    expect(store.running_commit).to be_nil
  end

  it "leaves a successful commit fully visible (sanity check)" do
    commit = store.commit(document, author: "a", message: "m")
    expect(commit).not_to be_nil
    expect(store.list_commits.length).to eq(1)
    expect(store.running_commit&.id).to eq(commit.id)
  end
end
