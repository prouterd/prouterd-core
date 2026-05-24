require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Configs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }
  after { db.close }

  describe "#latest_commit" do
    it "returns nil when there are no commits" do
      expect(repo.latest_commit).to be_nil
    end

    it "returns the newest commit by id" do
      repo.save_commit(rendered_config: "router a\nexit\n", author: "x")
      c2 = repo.save_commit(rendered_config: "router b\nexit\n", author: "y")
      latest = repo.latest_commit
      expect(latest.id).to eq(c2.id)
      expect(latest.author).to eq("y")
    end
  end
end
