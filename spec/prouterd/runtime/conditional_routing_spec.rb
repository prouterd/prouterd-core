require "spec_helper"

RSpec.describe "Phase 5 conditional routing in Orchestrator" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  describe "match conditions on outgoing routes" do
    let(:document) do
      parse(<<~PRC)
        router demo
        exit
        process p
         block score
          image x
          input event.body
          output lead.scored
         exit
         block notify_sales
          image x
          input lead.scored
          output sales.notified
         exit
         block notify_marketing
          image x
          input lead.scored
          output marketing.notified
         exit
         route score notify_sales
          match lead.scored.score gt 70
         exit
         route score notify_marketing
          match lead.scored.score lte 70
         exit
        exit
      PRC
    end

    it "follows the high-score branch when score > 70" do
      runner.program("score", &Prouterd::Runner::StubRunner.success(output: { "score" => 85 }))
      runner.program("notify_sales",     &Prouterd::Runner::StubRunner.success)
      runner.program("notify_marketing", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to contain_exactly("score", "notify_sales")
      expect(run.status).to eq("success")
    end

    it "follows the low-score branch when score <= 70" do
      runner.program("score", &Prouterd::Runner::StubRunner.success(output: { "score" => 40 }))
      runner.program("notify_sales",     &Prouterd::Runner::StubRunner.success)
      runner.program("notify_marketing", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to contain_exactly("score", "notify_marketing")
    end

    it "executes both branches when both conditions are simultaneously satisfied" do
      doc = parse(<<~PRC)
        router demo
        exit
        process p
         block start
          image x
          output result
         exit
         block left
          image x
          output l
         exit
         block right
          image x
          output r
         exit
         route start left
          match event.flag eq "go"
         exit
         route start right
          match event.flag eq "go"
         exit
        exit
      PRC
      runner.default(&Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(doc, "p", input_event: { "flag" => "go" })
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to contain_exactly("start", "left", "right")
    end

    it "prunes both branches when no condition matches" do
      runner.program("score", &Prouterd::Runner::StubRunner.success(output: { "different_field" => 1 }))
      runner.program("notify_sales",     &Prouterd::Runner::StubRunner.success)
      runner.program("notify_marketing", &Prouterd::Runner::StubRunner.success)

      run = orchestrator.trigger(document, "p", input_event: {})
      executed = repo.list_steps(run.id).map(&:block_name)
      expect(executed).to eq(["score"])
      expect(run.status).to eq("success")
    end
  end

  describe "parallel level execution" do
    it "runs same-level blocks concurrently" do
      doc = parse(<<~PRC)
        router demo
        exit
        process fan
         block start
          image x
          output result
         exit
         block left
          image x
          output l
         exit
         block right
          image x
          output r
         exit
         route start left
         route start right
        exit
      PRC

      mutex = Mutex.new
      timeline = []
      runner.program("start", &Prouterd::Runner::StubRunner.success)
      runner.program("left") do |_req|
        mutex.synchronize { timeline << :left_start }
        sleep 0.05
        mutex.synchronize { timeline << :left_end }
        Prouterd::Runner::StubRunner.success.call(_req)
      end
      runner.program("right") do |_req|
        mutex.synchronize { timeline << :right_start }
        sleep 0.05
        mutex.synchronize { timeline << :right_end }
        Prouterd::Runner::StubRunner.success.call(_req)
      end

      run = orchestrator.trigger(doc, "fan", input_event: {})
      expect(run.status).to eq("success")
      # If parallel, both starts come before both ends.
      starts = timeline.each_with_index.select { |s, _| s.to_s.end_with?("start") }.map(&:last)
      ends   = timeline.each_with_index.select { |s, _| s.to_s.end_with?("end") }.map(&:last)
      expect(starts.max).to be < ends.min
    end
  end
end
