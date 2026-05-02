require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Configs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }

  after { db.close }

  describe "save_commit + get_commit" do
    it "persists rendered config and computes checksum" do
      commit = repo.save_commit(
        rendered_config: "router x\nexit\n",
        author: "alice",
        message: "initial"
      )
      expect(commit.id).to be_a(Integer)
      expect(commit.checksum).to match(/\A[0-9a-f]{64}\z/)
      expect(commit.author).to eq("alice")
      expect(commit.message).to eq("initial")
      expect(commit.rendered_config).to include("router x")
    end

    it "round-trips a commit by id" do
      saved = repo.save_commit(rendered_config: "router x\nexit\n")
      fetched = repo.get_commit(saved.id)
      expect(fetched.id).to eq(saved.id)
      expect(fetched.checksum).to eq(saved.checksum)
      expect(fetched.rendered_config).to eq(saved.rendered_config)
    end

    it "returns nil for unknown id" do
      expect(repo.get_commit(99_999)).to be_nil
    end

    it "auto-increments commit ids" do
      a = repo.save_commit(rendered_config: "router a\nexit\n")
      b = repo.save_commit(rendered_config: "router b\nexit\n")
      expect(b.id).to be > a.id
    end

    it "two commits with the same body produce the same checksum but distinct ids" do
      a = repo.save_commit(rendered_config: "router x\nexit\n")
      b = repo.save_commit(rendered_config: "router x\nexit\n")
      expect(a.checksum).to eq(b.checksum)
      expect(a.id).not_to eq(b.id)
    end
  end

  describe "list_commits / count_commits" do
    it "lists newest first" do
      ids = []
      3.times do |i|
        ids << repo.save_commit(rendered_config: "router r#{i}\nexit\n").id
      end
      listed = repo.list_commits.map(&:id)
      expect(listed).to eq(ids.reverse)
    end

    it "honors limit and offset" do
      5.times { |i| repo.save_commit(rendered_config: "router r#{i}\nexit\n") }
      page1 = repo.list_commits(limit: 2, offset: 0)
      page2 = repo.list_commits(limit: 2, offset: 2)
      expect(page1.length).to eq(2)
      expect(page2.length).to eq(2)
      expect(page1.map(&:id) & page2.map(&:id)).to be_empty
    end

    it "count matches" do
      4.times { |i| repo.save_commit(rendered_config: "router r#{i}\nexit\n") }
      expect(repo.count_commits).to eq(4)
    end
  end

  describe "pointers" do
    it "set/get round-trip" do
      c = repo.save_commit(rendered_config: "router x\nexit\n")
      repo.set_pointer("running", c.id)
      ptr = repo.get_pointer("running")
      expect(ptr.commit_id).to eq(c.id)
      expect(ptr.name).to eq("running")
    end

    it "set updates an existing pointer" do
      a = repo.save_commit(rendered_config: "router a\nexit\n")
      b = repo.save_commit(rendered_config: "router b\nexit\n")
      repo.set_pointer("running", a.id)
      repo.set_pointer("running", b.id)
      expect(repo.get_pointer("running").commit_id).to eq(b.id)
    end

    it "running and startup are independent" do
      a = repo.save_commit(rendered_config: "router a\nexit\n")
      b = repo.save_commit(rendered_config: "router b\nexit\n")
      repo.set_pointer("running", b.id)
      repo.set_pointer("startup", a.id)
      expect(repo.get_pointer("running").commit_id).to eq(b.id)
      expect(repo.get_pointer("startup").commit_id).to eq(a.id)
    end

    it "returns nil for unset pointer" do
      expect(repo.get_pointer("running")).to be_nil
    end
  end
end
