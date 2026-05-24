require "spec_helper"

# `route X parallel_name [match ...]` fans out to every member of
# the named parallel group instead of routing into the barrier as a
# single node. Members are gated by the external route — they no
# longer auto-fire as entry blocks when the barrier has incoming
# edges — and the barrier itself enqueues normally via the
# synthesized member→barrier routes once members finish.
RSpec.describe "route into parallel group fans out to members" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  IFACES_FAN = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(IFACES_FAN + prc))
  end

  describe "with a single external route into the barrier" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block upstream
          interface docker img1
         exit

         parallel after_health
          join-strategy all-best-effort
          block a
           interface docker img1
          exit
          block b
           interface docker img1
          exit
          block c
           interface docker img1
          exit
         exit

         block downstream
          interface docker img1
         exit

         route upstream after_health
         route after_health downstream
        exit
      PRC
    end

    it "triggers every member and the barrier aggregates them" do
      runner.program("upstream",   &Prouterd::Runner::StubRunner.success(output: { "ok" => true }))
      runner.program("a",          &Prouterd::Runner::StubRunner.success(output: { "n" => 1 }))
      runner.program("b",          &Prouterd::Runner::StubRunner.success(output: { "n" => 2 }))
      runner.program("c",          &Prouterd::Runner::StubRunner.success(output: { "n" => 3 }))
      runner.program("downstream", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")

      ran = runner.calls.map(&:block_name)
      expect(ran).to eq(%w[upstream a b c downstream])

      steps = repo.list_steps(run.id).group_by(&:block_name).transform_values(&:first)
      barrier_out = JSON.parse(steps["after_health"].output_json)
      expect(barrier_out["succeeded"]).to contain_exactly("a", "b", "c")
      expect(barrier_out["members"]).to eq("a" => { "n" => 1 }, "b" => { "n" => 2 }, "c" => { "n" => 3 })
    end

    it "members do NOT auto-fire as entry blocks when gated by an external route" do
      runner.program("upstream",   &Prouterd::Runner::StubRunner.success)
      runner.program("a",          &Prouterd::Runner::StubRunner.success)
      runner.program("b",          &Prouterd::Runner::StubRunner.success)
      runner.program("c",          &Prouterd::Runner::StubRunner.success)
      runner.program("downstream", &Prouterd::Runner::StubRunner.success)

      orchestrator.trigger(document, "p", input_event: {})
      first_call_block = runner.calls.first.block_name
      # Without the gating in entry_blocks, members would race upstream
      # and run at level 0. With it, upstream runs first.
      expect(first_call_block).to eq("upstream")
    end
  end

  describe "with a match condition on the external route" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block decide
          interface docker img1
         exit

         parallel collect
          join-strategy all-required
          block fetch_a
           interface docker img1
          exit
          block fetch_b
           interface docker img1
          exit
         exit

         route decide collect
          match decide.go eq true
         exit
        exit
      PRC
    end

    it "fans out only when the match passes" do
      runner.program("decide",  &Prouterd::Runner::StubRunner.success(output: { "go" => true }))
      runner.program("fetch_a", &Prouterd::Runner::StubRunner.success(output: { "v" => "a" }))
      runner.program("fetch_b", &Prouterd::Runner::StubRunner.success(output: { "v" => "b" }))

      orchestrator.trigger(document, "p", input_event: {})
      expect(runner.calls.map(&:block_name)).to contain_exactly("decide", "fetch_a", "fetch_b")
    end

    it "skips the fan-out when the match fails" do
      runner.program("decide", &Prouterd::Runner::StubRunner.success(output: { "go" => false }))

      orchestrator.trigger(document, "p", input_event: {})
      # Only `decide` runs; members were never triggered and the
      # barrier never fires (no synthesized members ran).
      expect(runner.calls.map(&:block_name)).to eq(%w[decide])
    end
  end

  describe "with multiple external routes into the same barrier" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block trigger_one
          interface docker img1
         exit
         block trigger_two
          interface docker img1
         exit

         parallel work
          join-strategy all-best-effort
          block w1
           interface docker img1
          exit
          block w2
           interface docker img1
          exit
         exit

         route trigger_one work
         route trigger_two work
        exit
      PRC
    end

    it "deduplicates members across both routes" do
      runner.program("trigger_one", &Prouterd::Runner::StubRunner.success)
      runner.program("trigger_two", &Prouterd::Runner::StubRunner.success)
      runner.program("w1",          &Prouterd::Runner::StubRunner.success)
      runner.program("w2",          &Prouterd::Runner::StubRunner.success)

      orchestrator.trigger(document, "p", input_event: {})
      # Each member runs exactly once even though both external routes
      # point at the barrier.
      counts = runner.calls.map(&:block_name).tally
      expect(counts["w1"]).to eq(1)
      expect(counts["w2"]).to eq(1)
    end
  end
end
