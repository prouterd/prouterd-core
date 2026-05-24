require "spec_helper"

RSpec.describe Prouterd::ControlPlane::ConfigStore do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { described_class.new(db) }
  after { db.close }

  def parse(prc_text)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc_text))
  end

  describe "#load_startup" do
    it "returns an empty Document when nothing has been saved" do
      doc = store.load_startup
      expect(doc).to be_a(Prouterd::Config::AST::Document)
      expect(doc.router).to be_nil
    end

    it "returns the parsed startup document after write_memory" do
      store.commit(parse(read_fixture("minimal.prc")))
      store.write_memory
      doc = store.load_startup
      expect(doc).to be_a(Prouterd::Config::AST::Document)
      expect(doc.router).not_to be_nil
    end
  end

  describe "#get_commit" do
    it "returns nil for an unknown id" do
      expect(store.get_commit(999_999)).to be_nil
    end

    it "returns the Commit for a known id" do
      c = store.commit(parse(read_fixture("minimal.prc")))
      expect(store.get_commit(c.id).id).to eq(c.id)
    end
  end

  describe "#load_running with a dangling pointer" do
    it "returns an empty Document when the pointer references a missing commit" do
      db.execute("PRAGMA foreign_keys = OFF")
      begin
        db.execute(
          "INSERT OR REPLACE INTO config_pointers(name, commit_id, updated_at) VALUES('running', ?, datetime('now'))",
          [999_999]
        )
        doc = store.load_running
        expect(doc).to be_a(Prouterd::Config::AST::Document)
        expect(doc.router).to be_nil
      ensure
        db.execute("PRAGMA foreign_keys = ON")
      end
    end
  end

  describe "#write_memory when commit lookup yields nil" do
    it "still updates the pointer and logs commit_id: nil safely" do
      c = store.commit(parse(read_fixture("minimal.prc")))
      db.execute("PRAGMA foreign_keys = OFF")
      begin
        db.execute("DELETE FROM config_commits WHERE id = ?", [c.id])
        result = store.write_memory
        expect(result).to be_nil
      ensure
        db.execute("PRAGMA foreign_keys = ON")
      end
    end
  end
end
