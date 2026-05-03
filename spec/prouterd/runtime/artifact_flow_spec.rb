require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "Typed artifacts: producer -> consumer" do
  let(:db)              { Prouterd::Storage::DB.open(":memory:") }
  let(:runner)          { Prouterd::Runner::StubRunner.new }
  let(:artifacts_root)  { Dir.mktmpdir("prouterd-artifacts-spec-") }
  let(:artifact_store)  { Prouterd::Runtime::ArtifactStore.new(artifacts_root) }
  let(:orchestrator) do
    Prouterd::Runtime::Orchestrator.new(db: db, runner: runner, artifact_store: artifact_store)
  end
  let(:repo) { Prouterd::Storage::Repositories::Runs.new(db) }

  after do
    db.close
    FileUtils.remove_entry(artifacts_root) if File.directory?(artifacts_root)
  end

  def parse(prc)
    Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
  end

  let(:document) do
    parse(<<~PRC)
      router demo
      exit
      process p
       block train
        image trainer:v1
        produces model.pkl
        produces metrics.json
       exit
       block deploy
        image deploy:v1
        input from train.model.pkl
        input from train.metrics.json
       exit
       route train deploy
      exit
    PRC
  end

  # Helper: write a fake artifact file the StubRunner can hand back as if
  # the runner had written it into /prouter/artifacts/<name>.
  def fake_artifact(name, content)
    dir = Dir.mktmpdir("prouterd-fake-artifact-")
    path = File.join(dir, name.tr("/", "_"))
    File.write(path, content)
    Prouterd::Runner::ArtifactDescriptor.new(
      name: name, host_path: path, size_bytes: content.bytesize,
      content_type: nil, checksum: nil
    )
  end

  it "stages upstream artifacts into /prouter/inputs and PROUTER_INPUT_<NAME> env vars" do
    runner.program("train") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "ok" => true },
        artifacts: [
          fake_artifact("model.pkl", "MODEL-BYTES"),
          fake_artifact("metrics.json", '{"acc":0.92}')
        ],
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    runner.program("deploy") do |req|
      # Orchestrator should have set staged_inputs and the per-input env vars
      # by the time the consumer runs.
      expect(req.staged_inputs).to be_a(Hash)
      expect(req.staged_inputs.keys.sort).to eq(%w[metrics model])
      expect(File.read(req.staged_inputs["model"])).to eq("MODEL-BYTES")
      expect(File.read(req.staged_inputs["metrics"])).to eq('{"acc":0.92}')
      expect(req.env["PROUTER_INPUT_MODEL"]).to eq("/prouter/inputs/model")
      expect(req.env["PROUTER_INPUT_METRICS"]).to eq("/prouter/inputs/metrics")
      Prouterd::Runner::StubRunner.success(output: { "deployed" => true }).call(req)
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("success")
    expect(repo.list_steps(run.id).map(&:status)).to eq(%w[success success])
  end

  it "fails the producer with missing_artifact when a declared `produces` is absent" do
    runner.program("train") do |_req|
      Prouterd::Runner::ExecutionResult.new(
        exit_code: 0, stdout: "", stderr: "",
        output_json: { "ok" => true },
        artifacts: [fake_artifact("model.pkl", "ok")], # metrics.json missing
        error_type: nil, error_message: nil,
        duration_ms: 1, started_at: nil, finished_at: nil
      )
    end

    run = orchestrator.trigger(document, "p", input_event: {})
    expect(run.status).to eq("failed")

    train_step = repo.list_steps(run.id).find { |s| s.block_name == "train" }
    expect(train_step.status).to eq("failed")
    expect(train_step.error_type).to eq("missing_artifact")
    expect(train_step.error_message).to include("metrics.json")
    expect(runner.calls.map(&:block_name)).to eq(%w[train])
  end
end
