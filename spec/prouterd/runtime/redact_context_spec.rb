require "spec_helper"

# Phase 35c: secret values must never reach Context. If a block echoes
# `{{secret.X}}` back into its output_json (or constructs a JSON
# containing the resolved value any other way), Phase 35c forces the
# redactor's `[********]` mask onto every leaf string at orchestrator's
# context-set boundary AND on the persisted run_steps.output_json.
RSpec.describe "Phase 35c strict secret redaction in Context" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }
  let(:secret_resolver) do
    resolver = Class.new do
      def resolve(secret)
        { "S" => "leak-me-xyz" }[secret.name]
      end
    end.new
    resolver
  end
  let(:orchestrator) do
    Prouterd::Runtime::Orchestrator.new(db: db, runner: runner, secret_resolver: secret_resolver)
  end
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      secret S
       source env S
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block leaker
        interface shell host
       exit
       block consumer
        interface shell host
       exit
       route leaker consumer
      exit
      route interface cli process p
      exit
    PRC
  end

  it "redacts secret values from output_json before they reach Context or run_steps" do
    runner.program("leaker") do |req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: {
          "token" => "leak-me-xyz",
          "nested" => { "k" => "leak-me-xyz" },
          "list" => ["a", "leak-me-xyz", { "deep" => "leak-me-xyz" }],
          "untouched" => "fine"
        },
        artifacts: [],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end
    captured_input = nil
    runner.program("consumer") do |req|
      captured_input = req.input_json
      Prouterd::Runner::StubRunner.success.call(req)
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")

    # Persisted run_steps.output_json — masked at every leaf string
    leaker_step = repo.list_steps(run.id).find { |s| s.block_name == "leaker" }
    persisted = JSON.parse(leaker_step.output_json)
    expect(persisted["token"]).to eq("********")
    expect(persisted["nested"]["k"]).to eq("********")
    expect(persisted["list"][1]).to eq("********")
    expect(persisted["list"][2]["deep"]).to eq("********")
    expect(persisted["untouched"]).to eq("fine")

    # Downstream block's input_json (which carries `context`) — also
    # masked, because Context received the scrubbed copy.
    expect(captured_input["context"]["leaker"]["token"]).to eq("********")
    expect(captured_input["context"]["leaker"]["nested"]["k"]).to eq("********")
    expect(captured_input["context"]["leaker"]["untouched"]).to eq("fine")
  end
end
