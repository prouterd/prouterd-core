require "spec_helper"

# `merge <name>` construct — barrier over existing sibling blocks (not
# nested inside the merge section like `parallel`). Three strategies:
# any / all-required / all-best-effort. The scheduler defers AND-style
# barriers until every member has reached a terminal state, so members
# spread across BFS levels still aggregate correctly.
RSpec.describe "merge <name> container" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_MRG = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_MRG + prc))
  end

  describe "all-required" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block jira
          interface docker img1
         exit
         block slack
          interface docker img1
         exit
         block sentry
          interface docker img1
         exit

         merge evidence
          from jira, slack, sentry
          strategy all-required
         exit

         block analyze
          interface docker img1
         exit

         route evidence analyze
        exit
      PRC
    end

    it "aggregates all three members with members/succeeded/failed shape" do
      runner.program("jira",    &Prouterd::Runner::StubRunner.success(output: { "issues" => 4 }))
      runner.program("slack",   &Prouterd::Runner::StubRunner.success(output: { "msgs" => 7 }))
      runner.program("sentry",  &Prouterd::Runner::StubRunner.success(output: { "events" => 0 }))
      runner.program("analyze", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")

      steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
      output = JSON.parse(steps["evidence"].output_json)
      expect(output["join_strategy"]).to eq("all-required")
      expect(output["succeeded"]).to contain_exactly("jira", "slack", "sentry")
      expect(output["failed"]).to eq([])
      expect(output["members"]).to eq(
        "jira"   => { "issues" => 4 },
        "slack"  => { "msgs" => 7 },
        "sentry" => { "events" => 0 }
      )
    end

    it "fails the run on the first member failure (on_failure: stop)" do
      runner.program("jira",    &Prouterd::Runner::StubRunner.success)
      runner.program("slack",   &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "slack flaky"))
      runner.program("sentry",  &Prouterd::Runner::StubRunner.success)
      runner.program("analyze", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("slack")

      steps = repo.list_steps(run.id).map(&:block_name)
      expect(steps).not_to include("evidence")
      expect(steps).not_to include("analyze")
    end
  end

  describe "all-best-effort" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block fast
          interface docker img1
         exit
         block flaky
          interface docker img1
         exit

         merge evidence
          from fast, flaky
          strategy all-best-effort
         exit

         block sink
          interface docker img1
         exit

         route evidence sink
        exit
      PRC
    end

    it "barrier fires with survivors, run continues" do
      runner.program("fast",  &Prouterd::Runner::StubRunner.success(output: { "value" => 1 }))
      runner.program("flaky", &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "oops"))
      runner.program("sink",  &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")

      steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
      output = JSON.parse(steps["evidence"].output_json)
      expect(output["succeeded"]).to eq(["fast"])
      expect(output["failed"]).to eq(["flaky"])
      expect(output["members"]["fast"]).to eq("value" => 1)
      expect(output["members"]["flaky"]).to be_nil
    end
  end

  describe "any" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block first
          interface docker img1
         exit
         block second
          interface docker img1
         exit

         merge winner
          from first, second
          strategy any
         exit

         block sink
          interface docker img1
         exit

         route winner sink
        exit
      PRC
    end

    it "barrier output carries the winning member's output and name" do
      runner.program("first",  &Prouterd::Runner::StubRunner.success(output: { "value" => "one" }))
      runner.program("second", &Prouterd::Runner::StubRunner.success(output: { "value" => "two" }))
      runner.program("sink",   &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")

      steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
      output = JSON.parse(steps["winner"].output_json)
      expect(output["join_strategy"]).to eq("any")
      expect(output["winner"]).to be_a(String)
      expect(output["output"]).to be_a(Hash)
      expect(%w[first second]).to include(output["winner"])
    end
  end

  describe "cross-level members (AND barrier deferred)" do
    # `a` is an entry block; `b` runs only after `pre` completes. The
    # merge fires only when BOTH a AND b are terminal — without the
    # AND-style readiness gate, the barrier would enqueue on level 1
    # (after `a` finished) and see only `a` in context.
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block a
          interface docker img1
         exit
         block pre
          interface docker img1
         exit
         block b
          interface docker img1
         exit

         merge both
          from a, b
          strategy all-required
         exit

         block sink
          interface docker img1
         exit

         route pre b
         route both sink
        exit
      PRC
    end

    it "waits for the slow member before firing" do
      runner.program("a",    &Prouterd::Runner::StubRunner.success(output: { "v" => "a" }))
      runner.program("pre",  &Prouterd::Runner::StubRunner.success(output: { "v" => "pre" }))
      runner.program("b",    &Prouterd::Runner::StubRunner.success(output: { "v" => "b" }))
      runner.program("sink", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")

      steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
      output = JSON.parse(steps["both"].output_json)
      expect(output["succeeded"]).to contain_exactly("a", "b")
      expect(output["members"]).to eq(
        "a" => { "v" => "a" },
        "b" => { "v" => "b" }
      )
    end
  end
end
