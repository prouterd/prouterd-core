require "spec_helper"

# Behaviour spec for the optional-`docker-api` story (Phase 28).
#
# When `docker-api` isn't installed, dispatch through DockerRunner must
# NOT crash with NameError or LoadError. It should return a clean
# ExecutionResult with error_type:"missing_dependency" so retry-when /
# on-failure / dead-letter all flow normally and operators see a
# self-explaining error in `show run <uid>`.
RSpec.describe Prouterd::Runner::DockerRunner do
  describe "when docker-api is unavailable" do
    around do |example|
      original = Prouterd::Runner::DockerRunner.instance_variable_get(:@docker_available)
      Prouterd::Runner::DockerRunner.instance_variable_set(:@docker_available, false)
      # Reset CallRunner's cached caller instance so the around-block's
      # toggle takes effect even on subsequent calls in the same process.
      example.run
      Prouterd::Runner::DockerRunner.instance_variable_set(:@docker_available, original)
    end

    let(:request) do
      Prouterd::Runner::RunRequest.new(
        run_uid: "run_test", process_name: "p", block_name: "b",
        execution_type: "docker", attempt: 1,
        env: {}, input_json: {}, timeout_ms: nil,
        type_fields: { "image" => "alpine:1" }, staged_inputs: {}
      )
    end

    it "returns missing_dependency without raising" do
      result = described_class.new.run(request)
      expect(result.error_type).to eq("missing_dependency")
      expect(result.error_message).to include("docker-api")
      expect(result.exit_code).to be_nil
    end

    it "is dispatchable via CallRunner end-to-end" do
      runner = Prouterd::Runner::CallRunner.new
      db = Prouterd::Storage::DB.open(":memory:")
      orch = Prouterd::Runtime::Orchestrator.new(db: db, runner: runner)

      doc = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(<<~PRC))
        router demo
        exit
        interface docker img1
         image alpine
        exit
        process p
         block doit
          interface docker img1
         exit
        exit
      PRC

      run = orch.trigger(doc, "p", input_event: {})
      expect(run.status).to eq("failed")
      expect(run.error_summary).to include("missing_dependency")
      expect(run.error_summary).to include("docker-api")
      db.close
    end
  end
end
