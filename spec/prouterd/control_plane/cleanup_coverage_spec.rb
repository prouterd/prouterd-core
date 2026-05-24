require "spec_helper"

RSpec.describe Prouterd::ControlPlane::Cleanup do
  describe Prouterd::ControlPlane::Cleanup::Result do
    it "#total_rows sums runs+steps+logs+artifacts" do
      r = described_class.new(runs: 1, steps: 2, logs: 3, artifacts: 4,
                              artifact_files: 5, would_delete: false)
      expect(r.total_rows).to eq(10)
    end
  end

  describe ".sweep" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    after { db.close }

    it "returns a zero Result on an empty store (early-return branch)" do
      result = Prouterd::ControlPlane::Cleanup.sweep(db, older_than: 3600)
      expect(result.runs).to eq(0)
      expect(result.steps).to eq(0)
      expect(result.logs).to eq(0)
      expect(result.artifacts).to eq(0)
      expect(result.artifact_files).to eq(0)
      expect(result.would_delete).to be(false)
    end
  end

  describe "private branches via instance" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    after { db.close }

    it "count returns 0 for empty run_ids (line 102 early return)" do
      instance = Prouterd::ControlPlane::Cleanup.new(db, older_than: 60)
      result = instance.send(:count, "run_steps", [])
      expect(result).to eq(0)
    end

    it "run_uids_for returns [] for empty run_ids (line 115 early return)" do
      instance = Prouterd::ControlPlane::Cleanup.new(db, older_than: 60)
      result = instance.send(:run_uids_for, [])
      expect(result).to eq([])
    end
  end
end
