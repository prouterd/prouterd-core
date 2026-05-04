require "spec_helper"

RSpec.describe "Phase 25: retry-when, previous, iteration templating" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:orchestrator) { Prouterd::Runtime::Orchestrator.new(db: db, runner: runner) }
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  RETRY_WHEN_IFACES = <<~PRC.freeze
    interface docker img1
     image alpine:1
    exit
  PRC

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(RETRY_WHEN_IFACES + prc))
  end

  describe "retry-when on error_type" do
    let(:document) do
      parse(<<~PRC)
        router x
        exit
        policy retry_transient
         retry attempts 3
         retry backoff fixed
         retry initial-delay 1ms
         retry when error_type eq "non_zero_exit"
        exit
        process p
         block flaky
          interface docker img1
          retry policy retry_transient
         exit
        exit
      PRC
    end

    it "retries when the error_type matches the condition" do
      attempts = 0
      runner.default do |req|
        attempts += 1
        if attempts < 3
          Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom").call(req)
        else
          Prouterd::Runner::StubRunner.success.call(req)
        end
      end

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")
      steps = repo.list_steps(run.id)
      expect(steps.length).to eq(3)
      expect(steps.map(&:status)).to eq(%w[failed failed success])
    end

    it "stops retrying when the error_type does not match" do
      runner.default(&Prouterd::Runner::StubRunner.failure(error_type: "invalid_call", error_message: "bad input"))

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("failed")
      steps = repo.list_steps(run.id)
      # Only one attempt — retry-when said no.
      expect(steps.length).to eq(1)

      logs = repo.list_logs(run.id)
      system_logs = logs.select { |l| l.stream == "system" }
      expect(system_logs.map(&:content).join("\n")).to include("no retry-when condition matched")
    end
  end

  describe "retry-when with `in`" do
    let(:document) do
      parse(<<~PRC)
        router x
        exit
        policy multi_retry
         retry attempts 2
         retry backoff fixed
         retry initial-delay 1ms
         retry when error_type in "timeout","http_error","llm_error"
        exit
        process p
         block flaky
          interface docker img1
          retry policy multi_retry
         exit
        exit
      PRC
    end

    it "retries on any of the listed error types" do
      attempts = 0
      runner.default do |req|
        attempts += 1
        if attempts == 1
          Prouterd::Runner::StubRunner.failure(error_type: "http_error", error_message: "boom").call(req)
        else
          Prouterd::Runner::StubRunner.success.call(req)
        end
      end

      run = orchestrator.trigger(document, "p", input_event: {})
      expect(run.status).to eq("success")
      expect(repo.list_steps(run.id).length).to eq(2)
    end

    it "skips retry when error_type is outside the list" do
      runner.default(&Prouterd::Runner::StubRunner.failure(error_type: "missing_artifact", error_message: "lost"))
      run = orchestrator.trigger(document, "p", input_event: {})
      expect(repo.list_steps(run.id).length).to eq(1)
      expect(run.status).to eq("failed")
    end
  end

  describe "iteration + previous templating" do
    let(:document) do
      parse(<<~PRC)
        router x
        exit
        policy any_retry
         retry attempts 3
         retry backoff fixed
         retry initial-delay 1ms
        exit
        process p
         block work
          interface docker img1
          retry policy any_retry
          command "attempt {{iteration}} after {{previous.error_type}}: {{previous.error_message}}"
         exit
        exit
      PRC
    end

    it "exposes iteration starting at 1 and grows on each retry" do
      attempts_seen = []
      runner.default do |req|
        attempts_seen << req.field("command")
        Prouterd::Runner::StubRunner.failure(error_type: "transient", error_message: "again #{attempts_seen.length}").call(req)
      end

      orchestrator.trigger(document, "p", input_event: {})

      expect(attempts_seen[0]).to eq("attempt 1 after : ")
      expect(attempts_seen[1]).to eq("attempt 2 after transient: again 1")
      expect(attempts_seen[2]).to eq("attempt 3 after transient: again 2")
    end

    it "does not leak iteration / previous into other blocks' templates" do
      doc = parse(<<~PRC)
        router x
        exit
        process p
         block first
          interface docker img1
          command "x"
         exit
         block second
          interface docker img1
          command "saw {{iteration}} previous {{previous.error_type}}"
         exit
         route first second
        exit
      PRC

      seen = []
      runner.program("first", &Prouterd::Runner::StubRunner.success(output: { "ok" => true }))
      runner.program("second") do |req|
        seen << req.field("command")
        Prouterd::Runner::StubRunner.success.call(req)
      end

      orchestrator.trigger(doc, "p", input_event: {})
      # On second's only attempt, iteration=1 and previous is unset.
      expect(seen).to eq(["saw 1 previous "])
    end
  end

  describe "DSL roundtrip" do
    it "parser captures multiple retry-when clauses; renderer round-trips them" do
      src = <<~PRC
        router x
        exit
        policy multi
         retry attempts 3
         retry backoff fixed
         retry when error_type eq "timeout"
         retry when error_type in "http_error","llm_error"
        exit
      PRC

      doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(src))
      policy = doc.policies.first
      expect(policy.retry_when_matches.length).to eq(2)
      expect(policy.retry_when_matches[0].operator).to eq("eq")
      expect(policy.retry_when_matches[1].operator).to eq("in")

      first  = Prouterd::Config::Renderer.render(doc)
      second = Prouterd::Config::Renderer.render(
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(first))
      )
      expect(second).to eq(first)
      expect(first).to include('retry when error_type eq "timeout"')
      expect(first).to include('retry when error_type in "http_error","llm_error"')
    end
  end
end
