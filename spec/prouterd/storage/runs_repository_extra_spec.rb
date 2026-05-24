require "spec_helper"

RSpec.describe Prouterd::Storage::Repositories::Runs do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:repo) { described_class.new(db) }
  after { db.close }

  describe "#add_run_usage" do
    let(:run) { repo.create_run(process_name: "p", input_event: {}) }

    it "is a no-op when all three counters are zero" do
      repo.add_run_usage(run.id, tokens_in: 0, tokens_out: 0, cost_usd: 0.0)
      refreshed = repo.get_run(run.id)
      expect(refreshed.tokens_in).to eq(0)
      expect(refreshed.tokens_out).to eq(0)
      expect(refreshed.cost_usd).to eq(0.0)
    end

    it "accumulates non-zero counters" do
      repo.add_run_usage(run.id, tokens_in: 5, tokens_out: 0, cost_usd: 0.0)
      repo.add_run_usage(run.id, tokens_in: 0, tokens_out: 3, cost_usd: 0.0)
      repo.add_run_usage(run.id, tokens_in: 0, tokens_out: 0, cost_usd: 1.5)
      refreshed = repo.get_run(run.id)
      expect(refreshed.tokens_in).to eq(5)
      expect(refreshed.tokens_out).to eq(3)
      expect(refreshed.cost_usd).to eq(1.5)
    end
  end

  describe "#generate_uid collision retry" do
    it "retries when SecureRandom returns a collision then a fresh value" do
      existing = repo.create_run(process_name: "p", input_event: {})
      # Strip the "run_" prefix to reproduce the hex part the generator emits.
      collision_hex = existing.uid.sub(/\Arun_/, "")
      fresh_hex = "abcdef01"
      values = [collision_hex, fresh_hex]
      allow(SecureRandom).to receive(:hex).with(4) { values.shift }

      r = repo.create_run(process_name: "p", input_event: {})
      expect(r.uid).to eq("run_#{fresh_hex}")
    end
  end
end
