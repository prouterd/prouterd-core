require "spec_helper"

RSpec.describe Prouterd::ControlPlane::ConfigStore do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { described_class.new(db) }

  after { db.close }

  def parse(prc_text)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc_text))
  end

  let(:doc_minimal) { parse(read_fixture("minimal.prc")) }
  let(:doc_sales) { parse(read_fixture("sales_ops.prc")) }

  describe "#commit" do
    it "persists a commit and updates the running pointer atomically" do
      commit = store.commit(doc_minimal, author: "alice", message: "init")
      expect(commit.id).to be_a(Integer)
      expect(store.running_commit.id).to eq(commit.id)
      expect(store.startup_commit).to be_nil
    end

    it "subsequent commits advance the running pointer" do
      c1 = store.commit(doc_minimal)
      c2 = store.commit(doc_sales)
      expect(c2.id).to be > c1.id
      expect(store.running_commit.id).to eq(c2.id)
    end
  end

  describe "#load_running" do
    it "returns an empty Document when nothing committed" do
      doc = store.load_running
      expect(doc).to be_a(Prouterd::Config::AST::Document)
      expect(doc.router).to be_nil
    end

    it "round-trips through parse(render(commit))" do
      store.commit(doc_sales)
      loaded = store.load_running
      expect(loaded.router.name).to eq("sales_ops")
      expect(loaded.processes.length).to eq(1)
      expect(loaded.processes.first.blocks.map(&:name)).to eq(%w[extract enrich score notify_sales])
    end
  end

  describe "#write_memory" do
    it "blesses running as startup" do
      c = store.commit(doc_minimal)
      saved = store.write_memory
      expect(saved.id).to eq(c.id)
      expect(store.startup_commit.id).to eq(c.id)
    end

    it "raises when there is no running config" do
      expect { store.write_memory }.to raise_error(Prouterd::ControlPlane::ConfigStoreError, /no running config/)
    end
  end

  describe "#rollback" do
    it "moves running pointer back to a previous commit" do
      c1 = store.commit(doc_minimal)
      c2 = store.commit(doc_sales)
      expect(store.running_commit.id).to eq(c2.id)
      store.rollback(c1.id)
      expect(store.running_commit.id).to eq(c1.id)
    end

    it "leaves later commits in history (rollback is not deletion)" do
      c1 = store.commit(doc_minimal)
      c2 = store.commit(doc_sales)
      store.rollback(c1.id)
      expect(store.list_commits.map(&:id)).to include(c1.id, c2.id)
    end

    it "raises on unknown commit id" do
      expect { store.rollback(9999) }.to raise_error(Prouterd::ControlPlane::ConfigStoreError, /no such commit/)
    end
  end

  describe "across DB reopens" do
    it "preserves commits and pointers" do
      Tempfile.create(["prouterd-persist-", ".sqlite3"]) do |tmp|
        tmp.close
        db1 = Prouterd::Storage::DB.open(tmp.path)
        store1 = described_class.new(db1)
        c = store1.commit(doc_sales, author: "bob", message: "session 1")
        store1.write_memory
        db1.close

        db2 = Prouterd::Storage::DB.open(tmp.path)
        store2 = described_class.new(db2)
        expect(store2.running_commit.id).to eq(c.id)
        expect(store2.startup_commit.id).to eq(c.id)
        expect(store2.load_running.router.name).to eq("sales_ops")
        db2.close
      end
    end
  end
end
