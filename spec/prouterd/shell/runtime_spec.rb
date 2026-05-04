require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe "Phase 4 runtime through the shell" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:store) { Prouterd::ControlPlane::ConfigStore.new(db) }
  let(:runner) { Prouterd::Runner::StubRunner.new }

  after { db.close }

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  def commit(doc, message: "test")
    store.commit(doc, author: "test", message: message)
  end

  def drive(script)
    input  = StringIO.new(script.end_with?("\n") ? script : "#{script}\n")
    output = StringIO.new
    error  = StringIO.new
    session = Prouterd::Shell::Session.new(store: store, runner: runner)
    Prouterd::Shell::Shell.run(
      session: session,
      input: input, output: output, error: error,
      interactive: false, banner: false
    )
    [output.string, error.string]
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      interface docker img2
       image alpine:2
      exit
      process pipeline
       block extract
        interface docker img1
       exit
       block enrich
        interface docker img2
       exit
       route extract enrich
      exit
    PRC
  end

  before { commit(document) }

  describe "trigger" do
    it "runs the full DAG and prints a summary" do
      runner.default(&Prouterd::Runner::StubRunner.success(output: { "ok" => true }))

      Tempfile.create(["event-", ".json"]) do |tmp|
        tmp.write('{"body":"hello"}')
        tmp.flush

        out, _err = drive("enable\ntrigger process pipeline input #{tmp.path}\nexit\n")
        expect(out).to include("Run run_")
        expect(out).to include("success")
        expect(out).to include("extract")
        expect(out).to include("enrich")
      end
    end

    it "shows a failed run when a block fails" do
      runner.program("extract", &Prouterd::Runner::StubRunner.success(output: { "raw" => 1 }))
      runner.program("enrich",  &Prouterd::Runner::StubRunner.failure(error_type: "non_zero_exit", error_message: "boom"))

      Tempfile.create(["event-", ".json"]) do |tmp|
        tmp.write('{"body":"x"}')
        tmp.flush

        out, _err = drive("enable\ntrigger process pipeline input #{tmp.path}\nexit\n")
        expect(out).to include("failed")
        expect(out).to include("enrich")
        expect(out).to include("error: block 'enrich'")
      end
    end

    it "errors clearly when process is unknown" do
      Tempfile.create(["event-", ".json"]) do |tmp|
        tmp.write('{}')
        tmp.flush
        _out, err = drive("enable\ntrigger process ghost input #{tmp.path}\nexit\n")
        expect(err).to include("no such process 'ghost'")
      end
    end

    it "errors when input file is missing" do
      _out, err = drive("enable\ntrigger process pipeline input /nope/missing.json\nexit\n")
      expect(err).to include("no such input file")
    end

    it "errors when input file is invalid JSON" do
      Tempfile.create(["bad-", ".json"]) do |tmp|
        tmp.write("not json {")
        tmp.flush
        _out, err = drive("enable\ntrigger process pipeline input #{tmp.path}\nexit\n")
        expect(err).to include("not valid JSON")
      end
    end
  end

  describe "show runs / show run / show logs / show artifacts" do
    let(:run_uid) do
      runner.program("extract") do |_req|
        Prouterd::Runner::ExecutionResult.new(
          exit_code: 0, stdout: "extract-stdout\n", stderr: "extract-stderr\n",
          output_json: { "raw" => 1 }, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 5, started_at: nil, finished_at: nil
        )
      end
      runner.program("enrich", &Prouterd::Runner::StubRunner.success(output: { "score" => 99 }))

      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
      run = orch.trigger(document, "pipeline", input_event: { "body" => "hi" })
      run.uid
    end

    it "lists runs in show runs" do
      run_uid # trigger one run
      out, _err = drive("enable\nshow runs\nexit\n")
      expect(out).to include("UID")
      expect(out).to include(run_uid)
      expect(out).to include("pipeline")
    end

    it "shows run detail" do
      uid = run_uid
      out, _err = drive("enable\nshow run #{uid}\nexit\n")
      expect(out).to include("Run: #{uid}")
      expect(out).to include("extract")
      expect(out).to include("enrich")
      expect(out).to include("success")
    end

    it "shows logs by run with stream tags" do
      uid = run_uid
      out, _err = drive("enable\nshow logs run #{uid}\nexit\n")
      expect(out).to include("[extract/stdout]")
      expect(out).to include("extract-stdout")
      expect(out).to include("[extract/stderr]")
    end

    it "filters logs by block" do
      uid = run_uid
      out, _err = drive("enable\nshow logs run #{uid} block extract\nexit\n")
      expect(out).to include("[extract/stdout]")
      expect(out).not_to include("[enrich/")
    end

    it "errors on unknown run uid" do
      _out, err = drive("enable\nshow run run_deadbeef\nexit\n")
      expect(err).to include("no such run")
    end
  end

  describe "trace command" do
    it "renders trace output for a matching event" do
      # Use the canonical sales_ops fixture which has interface + global route.
      sales_doc = Prouterd::Config::Parser.parse(
        Prouterd::Config::Lexer.tokenize(read_fixture("sales_ops.prc"))
      )
      store2 = Prouterd::ControlPlane::ConfigStore.new(db)
      store2.commit(sales_doc)

      Tempfile.create(["evt-", ".json"]) do |tmp|
        tmp.write('{"type":"lead.created","body":{"name":"Acme"}}')
        tmp.flush

        input = StringIO.new("enable\ntrace event #{tmp.path} interface leads_in\nexit\n")
        output = StringIO.new
        error = StringIO.new
        session = Prouterd::Shell::Session.new(store: store2, runner: runner)
        Prouterd::Shell::Shell.run(
          session: session,
          input: input, output: output, error: error,
          interactive: false, banner: false
        )
        expect(output.string).to include("Trace result")
        expect(output.string).to include("Selected process")
        expect(output.string).to include("lead_pipeline")
        expect(output.string).to include("score -> notify_sales")
      end
    end

    it "errors on missing event file" do
      _out, err = drive("enable\ntrace event /nope/missing.json\nexit\n")
      expect(err).to include("no such event file")
    end
  end
end
