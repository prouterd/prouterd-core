require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Runner::ShellRunner do
  let(:runner) { described_class.new }

  def request(command:, **opts)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "shell", attempt: 1,
      command: command, env: opts[:env] || {}, input_json: opts[:input] || {},
      timeout_ms: opts[:timeout_ms], cwd: opts[:cwd]
    )
  end

  it "runs a successful shell command and parses output.json" do
    result = runner.run(request(command: %q[sh -c 'echo "{\"ok\":true}" > $PROUTER_OUTPUT_PATH']))
    expect(result.error_type).to be_nil
    expect(result.exit_code).to eq(0)
    expect(result.output_json).to eq("ok" => true)
    expect(result.success?).to be(true)
  end

  it "captures stdout and stderr" do
    result = runner.run(request(command: %q[sh -c 'echo HI; echo ERR >&2; echo "{}" > $PROUTER_OUTPUT_PATH']))
    expect(result.stdout).to include("HI")
    expect(result.stderr).to include("ERR")
  end

  it "returns missing_output when the command does not write the file" do
    result = runner.run(request(command: "true"))
    expect(result.error_type).to eq("missing_output")
  end

  it "returns invalid_output when the command writes garbage" do
    result = runner.run(request(command: %q[sh -c 'echo not-json > $PROUTER_OUTPUT_PATH']))
    expect(result.error_type).to eq("invalid_output")
  end

  it "returns non_zero_exit when the command fails" do
    result = runner.run(request(command: %q[sh -c 'echo nope >&2; exit 7']))
    expect(result.error_type).to eq("non_zero_exit")
    expect(result.exit_code).to eq(7)
  end

  it "respects timeout" do
    result = runner.run(request(command: "sleep 5", timeout_ms: 200))
    expect(result.error_type).to eq("timeout")
  end

  it "passes PROUTER_RUN_ID and other env to the process" do
    cmd = %q[sh -c 'printf %s "{\"run\":\"$PROUTER_RUN_ID\",\"block\":\"$PROUTER_BLOCK_NAME\"}" > $PROUTER_OUTPUT_PATH']
    env = { "PROUTER_RUN_ID" => "run_42", "PROUTER_BLOCK_NAME" => "greet" }
    result = runner.run(request(command: cmd, env: env))
    expect(result.output_json).to eq("run" => "run_42", "block" => "greet")
  end

  it "honors cwd" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "marker.txt"), "found-it")
      result = runner.run(request(
        command: %q[sh -c 'cat marker.txt > /tmp/prouterd-cwd-test; echo "{\"ok\":true}" > $PROUTER_OUTPUT_PATH'],
        cwd: dir
      ))
      expect(result.success?).to be(true)
      expect(File.read("/tmp/prouterd-cwd-test")).to eq("found-it")
      File.delete("/tmp/prouterd-cwd-test")
    end
  end

  it "errors when cwd does not exist" do
    result = runner.run(request(command: "true", cwd: "/nope/does/not/exist"))
    expect(result.error_type).to eq("invalid_cwd")
  end

  it "collects artifacts from $PROUTER_ARTIFACTS_DIR" do
    cmd = %q[sh -c 'echo "{}" > $PROUTER_OUTPUT_PATH; echo file-content > $PROUTER_ARTIFACTS_DIR/produced.txt']
    result = runner.run(request(command: cmd))
    expect(result.success?).to be(true)
    expect(result.artifacts.length).to eq(1)
    expect(result.artifacts.first.name).to eq("produced.txt")
    expect(result.artifacts.first.size_bytes).to be > 0
  end
end
