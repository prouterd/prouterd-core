require "spec_helper"

# {{system.url}} surfaces the daemon's bind URL to in-process
# templates so blocks can build self-pointing callbacks (HTTP
# self-call into /v1, Slack interaction handlers, webhook return
# addresses) without hardcoding host/port.
RSpec.describe "{{system.url}} runtime context root" do
  let(:db) { Prouterd::Storage::DB.open(":memory:") }
  let(:runner) { Prouterd::Runner::StubRunner.new }

  after { db.close }

  let(:document) do
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
      router demo
      exit
      interface docker img1
       image alpine:1
      exit
      process p
       block use_url
        interface docker img1
        command "curl {{system.url}}/v1/status"
       exit
      exit
    PRC
  end

  it "renders {{system.url}} into a block's call-fields when system_url is set" do
    orchestrator = Prouterd::Runtime::Orchestrator.new(
      db: db, runner: runner, system_url: "http://daemon:9000"
    )

    captured = nil
    runner.default { |req| captured = req; Prouterd::Runner::ExecutionResult.new(
      exit_code: 0, stdout: "", stderr: "",
      output_json: {}, artifacts: [],
      error_type: nil, error_message: nil,
      duration_ms: 1, started_at: nil, finished_at: nil
    ) }

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")
    # The runner sees the templated string with {{system.url}} replaced.
    expect(captured.type_fields["command"]).to eq("curl http://daemon:9000/v1/status")
  end

  it "leaves {{system.url}} empty when system_url is not configured" do
    orchestrator = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)
    captured = nil
    runner.default { |req| captured = req; Prouterd::Runner::ExecutionResult.new(
      exit_code: 0, stdout: "", stderr: "", output_json: {}, artifacts: [],
      error_type: nil, error_message: nil, duration_ms: 1,
      started_at: nil, finished_at: nil
    ) }

    orchestrator.trigger(document, "p", input_event: {})
    # Templater renders missing path as "" (empty string) — defensive default.
    expect(captured.type_fields["command"]).to eq("curl /v1/status")
  end
end
