require "spec_helper"

RSpec.describe Prouterd::API::Metrics do
  let(:metrics) { described_class.new }

  describe "#increment + #counters" do
    it "starts at zero for unseen keys (Hash.new(0))" do
      expect(metrics.counters[[:never_touched, {}]]).to eq(0)
    end

    it "accumulates a counter without labels" do
      metrics.increment(:runs_total)
      metrics.increment(:runs_total)
      metrics.increment(:runs_total, by: 3)
      expect(metrics.counters[[:runs_total, {}]]).to eq(5)
    end

    it "keys labels into a stable hash regardless of insertion order" do
      metrics.increment(:step_total, block: "a", status: "ok")
      metrics.increment(:step_total, status: "ok", block: "a")
      expect(metrics.counters[[:step_total, { block: "a", status: "ok" }]]).to eq(2)
    end

    it "keeps separate buckets per distinct label set" do
      metrics.increment(:step_total, block: "a", status: "ok")
      metrics.increment(:step_total, block: "a", status: "fail")
      metrics.increment(:step_total, block: "b", status: "ok")
      expect(metrics.counters[[:step_total, { block: "a", status: "ok" }]]).to eq(1)
      expect(metrics.counters[[:step_total, { block: "a", status: "fail" }]]).to eq(1)
      expect(metrics.counters[[:step_total, { block: "b", status: "ok" }]]).to eq(1)
    end

    it "is safe under concurrent increments" do
      threads = 8.times.map do
        Thread.new { 250.times { metrics.increment(:hot, by: 1) } }
      end
      threads.each(&:join)
      expect(metrics.counters[[:hot, {}]]).to eq(8 * 250)
    end
  end

  describe "#render" do
    it "emits HELP/TYPE/value lines for uptime as a gauge" do
      out = metrics.render
      expect(out).to include("# HELP prouterd_uptime_seconds")
      expect(out).to include("# TYPE prouterd_uptime_seconds gauge")
      expect(out).to match(/^prouterd_uptime_seconds \d+(\.\d+)?$/)
    end

    it "omits in_flight_runs gauge when no registry is wired" do
      expect(metrics.render).not_to include("prouterd_in_flight_runs")
    end

    it "renders the in_flight gauge from the registry" do
      registry = instance_double("InFlightRegistry", in_flight_count: 4)
      m = described_class.new(in_flight: registry)
      expect(m.render).to include("prouterd_in_flight_runs 4")
    end

    it "renders counters grouped by name with HELP/TYPE preamble" do
      metrics.increment(:runs_total, process: "p1", status: "success")
      metrics.increment(:runs_total, process: "p1", status: "failed")
      out = metrics.render

      expect(out).to include("# HELP prouterd_runs_total Cumulative count.")
      expect(out).to include("# TYPE prouterd_runs_total counter")
      expect(out).to include(%(prouterd_runs_total{process="p1",status="success"} 1))
      expect(out).to include(%(prouterd_runs_total{process="p1",status="failed"} 1))
    end

    it "renders an unlabeled counter without a label block" do
      metrics.increment(:bare_total, by: 7)
      expect(metrics.render).to include("prouterd_bare_total 7\n")
    end

    it "ends with a trailing newline" do
      expect(metrics.render).to end_with("\n")
    end

    it "escapes label values" do
      metrics.increment(:weird, name: %(quote " backslash \\ newline \n end))
      out = metrics.render
      # \\\\ — escaped backslash, \\\" — escaped quote, \\n — literal "\n"
      expect(out).to include(%(name="quote \\" backslash \\\\ newline \\n end))
    end
  end
end
