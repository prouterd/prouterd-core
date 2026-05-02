require "spec_helper"

RSpec.describe "Phase 13 contract enforcement in Orchestrator" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def doc_with_violation(on_violation)
    parse(<<~PRC)
      router x
      exit
      contract scored
       require score type integer min 70 max 100
       on violation #{on_violation}
      exit
      process p
       block scorer
        type docker
         image x
        exit
        output result
        contract scored
       exit
      exit
    PRC
  end

  describe "on violation fail (default)" do
    it "marks run failed when output violates contract" do
      doc = parse(<<~PRC)
        router x
        exit
        contract scored
         require score type integer min 70
        exit
        process p
         block scorer
          type docker
           image x
          exit
          output result
          contract scored
         exit
        exit
      PRC
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "score" => 50 }))

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("contract")
      expect(run.error_summary).to include("score")
    end

    it "passes when output satisfies contract" do
      doc = parse(<<~PRC)
        router x
        exit
        contract scored
         require score type integer min 70
        exit
        process p
         block scorer
          type docker
           image x
          exit
          output result
          contract scored
         exit
        exit
      PRC
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "score" => 85 }))

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
    end
  end

  describe "on violation retry" do
    it "retries the block per its retry policy on violation" do
      doc = parse(<<~PRC)
        router x
        exit
        policy r3
         retry attempts 3
         retry backoff fixed
         retry initial-delay 1ms
        exit
        contract scored
         require score type integer min 70
         on violation retry
        exit
        process p
         block scorer
          type docker
           image x
          exit
          output result
          retry r3
          contract scored
         exit
        exit
      PRC

      attempts = 0
      runner.default do |req|
        attempts += 1
        score = attempts < 3 ? 30 : 90 # passes contract on 3rd attempt
        Prouterd::Runner::StubRunner.success(output: { "score" => score }).call(req)
      end

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
      expect(attempts).to eq(3)

      steps = repo.list_steps(run.id)
      expect(steps.length).to eq(3)
      expect(steps.first(2).map(&:status)).to all(eq("failed"))
      expect(steps.last.status).to eq("success")
      # The first 2 attempts failed with contract_violation
      expect(steps.first.error_type).to eq("contract_violation")
    end
  end

  describe "on violation warn" do
    it "logs the violation but lets the run succeed" do
      doc = doc_with_violation("warn")
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "score" => 30 }))

      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")

      logs = repo.list_logs(run.id, step_id: nil)
      system_logs = logs.select { |l| l.stream == "system" }
      expect(system_logs.map(&:content).join).to include("contract")
      expect(system_logs.map(&:content).join).to include("score")
    end
  end

  describe "no contract" do
    it "is a no-op when block has no contract declared" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block b
          type docker
           image x
          exit
          output r
         exit
        exit
      PRC
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "anything" => "goes" }))
      run = orchestrator.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("success")
    end
  end
end
