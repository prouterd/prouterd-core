require "spec_helper"

RSpec.describe Prouterd::Runtime::RetryEngine do
  describe ".resolve_dotted_path" do
    it "returns nil for nil root" do
      expect(described_class.resolve_dotted_path(nil, "x")).to be_nil
    end

    it "walks Hash by string key" do
      expect(described_class.resolve_dotted_path({ "a" => { "b" => 1 } }, "a.b")).to eq(1)
    end

    it "falls back to symbol key when string key is missing" do
      expect(described_class.resolve_dotted_path({ a: 5 }, "a")).to eq(5)
    end

    it "walks an Array with a numeric segment" do
      expect(described_class.resolve_dotted_path({ "xs" => [10, 20, 30] }, "xs.1")).to eq(20)
    end

    it "returns nil when intermediate hop is non-traversable" do
      expect(described_class.resolve_dotted_path({ "a" => 1 }, "a.b")).to be_nil
    end

    it "returns nil when array index segment is non-numeric" do
      expect(described_class.resolve_dotted_path({ "xs" => [1, 2] }, "xs.nope")).to be_nil
    end
  end

  describe "OverlayContext" do
    let(:base) do
      Class.new do
        def get(p)
          { "base.value" => 42 }[p.to_s]
        end
      end.new
    end

    it "returns the overlay value for a bare head" do
      ctx = described_class::OverlayContext.new(base, { "iteration" => 3 })
      expect(ctx.get("iteration")).to eq(3)
    end

    it "walks a Hash inside the overlay" do
      ctx = described_class::OverlayContext.new(base, { "previous" => { "attempt" => 2 } })
      expect(ctx.get("previous.attempt")).to eq(2)
    end

    it "indexes an Array inside the overlay" do
      ctx = described_class::OverlayContext.new(base, { "previous" => { "list" => [10, 20] } })
      expect(ctx.get("previous.list.1")).to eq(20)
    end

    it "returns nil when overlay walk hits a non-traversable hop" do
      ctx = described_class::OverlayContext.new(base, { "previous" => 5 })
      expect(ctx.get("previous.attempt")).to be_nil
    end

    it "returns nil when an array segment is non-numeric" do
      ctx = described_class::OverlayContext.new(base, { "p" => [1, 2, 3] })
      expect(ctx.get("p.nope")).to be_nil
    end

    it "falls through to base.get when head is not in overlay" do
      ctx = described_class::OverlayContext.new(base, { "iteration" => 1 })
      expect(ctx.get("base.value")).to eq(42)
    end

    it "returns nil when overlay misses and base does not respond to get" do
      ctx = described_class::OverlayContext.new(Object.new, { "iteration" => 1 })
      expect(ctx.get("anything.else")).to be_nil
    end
  end

  describe "#lookup_policy" do
    let(:engine) { described_class.new(runs: double) }

    it "returns nil when policy_name is nil" do
      doc = double(policies: [])
      expect(engine.send(:lookup_policy, doc, nil)).to be_nil
    end

    it "returns the matching policy" do
      policy = double(name: "r")
      doc = double(policies: [policy])
      expect(engine.send(:lookup_policy, doc, "r")).to eq(policy)
    end

    it "returns nil when not found" do
      doc = double(policies: [])
      expect(engine.send(:lookup_policy, doc, "r")).to be_nil
    end
  end

  describe "#foreign_predicate_path?" do
    let(:engine) { described_class.new(runs: double) }

    it "returns false for a bare key (no dot)" do
      expect(engine.send(:foreign_predicate_path?, "issues")).to be(false)
    end

    it "returns false for an inner-namespace head (output.*, error_type, etc.)" do
      %w[output.x error_type.x error_message.x exit_code.x].each do |p|
        expect(engine.send(:foreign_predicate_path?, p)).to be(false)
      end
    end

    it "returns true for a foreign head (block-name.*)" do
      expect(engine.send(:foreign_predicate_path?, "verify.status")).to be(true)
    end
  end

  describe "#match_against_result?" do
    let(:engine) { described_class.new(runs: double) }
    let(:result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "score" => 50 },
        artifacts: [], error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    it "returns false when policy has no retry_when matches" do
      policy = double(retry_when_matches: [])
      expect(engine.match_against_result?(policy, result)).to be(false)
    end

    it "evaluates a single match against output.* synthetic overlay" do
      match = Prouterd::Config::AST::Match.new(path: "output.score", operator: "lt", values: [100], line: 1)
      policy = double(retry_when_matches: [match])
      expect(engine.match_against_result?(policy, result)).to be(true)
    end
  end

  describe "#build_previous_summary" do
    let(:engine) { described_class.new(runs: double) }
    let(:result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 7, stdout: "out", stderr: "err",
        output_json: { "issues" => "many" },
        artifacts: [], error_type: "boom", error_message: "msg",
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    it "returns the basic summary with no feedback when policy is nil" do
      s = engine.build_previous_summary(result, 2, nil)
      expect(s["attempt"]).to eq(2)
      expect(s["error_type"]).to eq("boom")
      expect(s["stdout"]).to eq("out")
      expect(s["stderr"]).to eq("err")
    end

    it "resolves output.X feedback" do
      fb = double(from: "output.issues", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(result, 2, policy)
      expect(s["feedback"]).to eq("many")
    end

    it "returns nil for output.X when result has no output_json" do
      r = result.dup
      r.output_json = nil
      fb = double(from: "output.missing", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(r, 2, policy)
      expect(s["feedback"]).to be_nil
    end

    it "resolves a bare key against output_json when no context is provided" do
      fb = double(from: "issues", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(result, 2, policy)
      expect(s["feedback"]).to eq("many")
    end

    it "resolves a cross-block path against context when a context is provided" do
      ctx = Prouterd::Runtime::Context.new("verify" => { "status" => "fail" })
      fb = double(from: "verify.status", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(result, 2, policy, ctx)
      expect(s["feedback"]).to eq("fail")
    end

    it "falls back to output_json when context lookup returns nil" do
      ctx = Prouterd::Runtime::Context.new({})
      fb = double(from: "issues", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(result, 2, policy, ctx)
      expect(s["feedback"]).to eq("many")
    end

    it "respects ctx_mutex when given for cross-block lookup" do
      ctx = Prouterd::Runtime::Context.new("verify" => { "issues" => "yes" })
      mutex = Monitor.new
      fb = double(from: "verify.issues", into: "feedback")
      policy = double(retry_feedbacks: [fb])
      s = engine.build_previous_summary(result, 2, policy, ctx, mutex)
      expect(s["feedback"]).to eq("yes")
    end
  end

  describe "#stop_triggered?" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:engine) { described_class.new(runs: runs) }
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:block) { double(name: "b") }
    let(:db_mutex) { Monitor.new }

    it "returns false when policy is nil" do
      expect(engine.stop_triggered?(nil, run, block, db_mutex)).to be(false)
    end

    it "returns false when retry_stop_matches is empty" do
      policy = double(retry_stop_matches: [])
      expect(engine.stop_triggered?(policy, run, block, db_mutex)).to be(false)
    end

    it "returns false and writes no log when the run was deleted (refreshed nil)" do
      created = run  # materialize the let before stubbing get_run
      policy = double(retry_stop_matches: [double])
      allow(runs).to receive(:get_run).and_return(nil)
      expect(engine.stop_triggered?(policy, created, block, db_mutex)).to be(false)
    end

    it "returns true when a stop-on match fires against the run cost" do
      runs.add_run_usage(run.id, cost_usd: 5.0, tokens_in: 100, tokens_out: 50)
      match = Prouterd::Config::AST::Match.new(path: "run.cost_usd", operator: "gt", values: [1], line: 1)
      policy = double(retry_stop_matches: [match])
      expect(engine.stop_triggered?(policy, run, block, db_mutex)).to be(true)
    end
  end

  describe "#should_fire?" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:engine) { described_class.new(runs: runs) }
    let(:run) { runs.create_run(process_name: "p", process_config_commit_id: nil, input_event: {}, parent_run_id: nil, thread_id: nil) }
    let(:db_mutex) { Monitor.new }

    let(:block) { double(name: "b") }
    let(:success_result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "score" => 50 }, artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end
    let(:failure_result) do
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 1, stdout: "", stderr: "",
        output_json: nil, artifacts: [],
        error_type: "boom", error_message: "x",
        duration_ms: 0, started_at: nil, finished_at: nil
      )
    end

    it "returns false when policy is nil" do
      expect(engine.should_fire?(nil, success_result, run, block, db_mutex)).to be(false)
    end

    it "retries on failure when retry-when is absent (legacy)" do
      policy = double(retry_when_matches: [])
      expect(engine.should_fire?(policy, failure_result, run, block, db_mutex)).to be(true)
      expect(engine.should_fire?(policy, success_result, run, block, db_mutex)).to be(false)
    end

    it "retries on a matching retry-when even when result is successful" do
      m = Prouterd::Config::AST::Match.new(path: "output.score", operator: "lt", values: [100], line: 1)
      policy = double(retry_when_matches: [m])
      expect(engine.should_fire?(policy, success_result, run, block, db_mutex)).to be(true)
    end

    it "logs terminal-failure when retry-when does NOT match on a failure" do
      m = Prouterd::Config::AST::Match.new(path: "output.score", operator: "gt", values: [999], line: 1)
      policy = double(retry_when_matches: [m])
      expect(engine.should_fire?(policy, failure_result, run, block, db_mutex)).to be(false)
      logs = runs.list_logs(run.id)
      expect(logs.map(&:content).join).to include("no retry-when condition matched")
    end
  end

  describe "#downstream_reachable" do
    let(:engine) { described_class.new(runs: double) }

    it "walks routes BFS starting from a node, returning seen-set excluding start" do
      r1 = double(from_block: "a", to_block: "b")
      r2 = double(from_block: "b", to_block: "c")
      r3 = double(from_block: "x", to_block: "y")
      process = double(routes: [r1, r2, r3])
      seen = engine.send(:downstream_reachable, process, "a")
      expect(seen.to_a.sort).to eq(["b", "c"])
    end

    it "returns an empty set when there are no outgoing routes" do
      process = double(routes: [])
      expect(engine.send(:downstream_reachable, process, "a").to_a).to eq([])
    end
  end

  describe "#sweep_cross_block" do
    let(:db) { Prouterd::Storage::DB.open(":memory:") }
    let(:runs) { Prouterd::Storage::Repositories::Runs.new(db) }
    after { db.close }
    let(:engine) { described_class.new(runs: runs) }

    it "no-ops when no executed block has a foreign-path policy" do
      process = double
      document = double
      result = double
      executed = ["a"]
      ctx_mutex = Monitor.new
      ctx = Prouterd::Runtime::Context.new({})
      allow(process).to receive(:block).with("a").and_return(double(retry_policy_name: nil))
      allow(engine).to receive(:lookup_policy).and_return(nil)
      out = engine.sweep_cross_block(process, document, { "a" => result }, executed,
                                     ctx, ctx_mutex, { "a" => 0 }, {})
      expect(out[:retriggered]).to be_empty
    end

    it "skips an executed name that's no longer in the process (block lookup returns nil)" do
      process = double
      allow(process).to receive(:block).with("ghost").and_return(nil)
      ctx_mutex = Monitor.new
      ctx = Prouterd::Runtime::Context.new({})
      out = engine.sweep_cross_block(process, double, { "ghost" => double },
                                     ["ghost"], ctx, ctx_mutex, { "ghost" => 0 }, {})
      expect(out[:retriggered]).to eq([])
      expect(out[:cleared]).to be_empty
    end

    it "skips an executed block whose result is missing from block_results" do
      # Build a real policy + match so we reach the `next unless result` line.
      match = Prouterd::Config::AST::Match.new(path: "other.field", operator: "eq", values: ["x"], line: 1)
      policy = double(retry_when_matches: [match], retry_attempts: 3, retry_feedbacks: [])
      block = double(retry_policy_name: "r")
      process = double
      allow(process).to receive(:block).with("b").and_return(block)
      doc = double(policies: [double(name: "r")])
      allow(engine).to receive(:lookup_policy).with(doc, "r").and_return(policy)

      ctx_mutex = Monitor.new
      ctx = Prouterd::Runtime::Context.new({})
      out = engine.sweep_cross_block(process, doc, {}, # block_results empty
                                     ["b"], ctx, ctx_mutex, { "b" => 0 }, {})
      expect(out[:retriggered]).to eq([])
    end
  end
end
