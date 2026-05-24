require "spec_helper"
require "tempfile"

RSpec.describe Prouterd::Runner::ShellRunner do
  let(:runner) { described_class.new }

  def request(command:, **opts)
    fields = { "exec" => command }
    fields["cwd"] = opts[:cwd] if opts.key?(:cwd)
    fields["env"] = opts[:custom_env] if opts.key?(:custom_env)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "shell", attempt: 1,
      env: opts[:env] || {}, input_json: opts[:input] || {},
      timeout_ms: opts[:timeout_ms], type_fields: fields
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

  it "caps captured stdout" do
    ENV["PROUTERD_LOG_CAPTURE_BYTES"] = "1000"
    result = runner.run(request(command: %q[sh -c 'yes x | head -c 200000; echo "{}" > $PROUTER_OUTPUT_PATH']))
    expect(result.stdout.bytesize).to be <= 1100
    expect(result.stdout).to include("truncated")
  ensure
    ENV.delete("PROUTERD_LOG_CAPTURE_BYTES")
  end

  it "treats exit-0 with no output.json as success with empty output_json" do
    # Shell blocks frequently exist for side effects (echo, notify, tail).
    # Forcing them all to synthesize JSON into /prouter/output.json is
    # exactly the kind of ceremony Phase 23/29 was meant to remove.
    result = runner.run(request(command: "true"))
    expect(result.error_type).to be_nil
    expect(result.exit_code).to eq(0)
    expect(result.output_json).to eq({})
  end

  it "parses stdout as JSON when output.json is absent (Hash)" do
    result = runner.run(request(command: %q[sh -c "echo '{\"score\":85}'"]))
    expect(result.error_type).to be_nil
    expect(result.output_json).to eq("score" => 85)
  end

  it "parses stdout as JSON when output.json is absent (Array)" do
    result = runner.run(request(command: %q[sh -c "echo '[1,2,3]'"]))
    expect(result.output_json).to eq([1, 2, 3])
  end

  it "leaves output_json={} when stdout is plain log text" do
    result = runner.run(request(command: %q[sh -c 'echo just a log line']))
    expect(result.error_type).to be_nil
    expect(result.output_json).to eq({})
  end

  it "leaves output_json={} when stdout is a non-Hash/Array JSON scalar" do
    # JSON.parse("42") returns 42 — that's a scalar, not a useful block
    # output. Treat as "no JSON output" rather than overriding the file.
    result = runner.run(request(command: %q[sh -c 'echo 42']))
    expect(result.output_json).to eq({})
  end

  it "output.json overrides stdout when both are present" do
    cmd = %q[sh -c 'echo {\"from\":\"stdout\"}; echo {\"from\":\"file\"} > $PROUTER_OUTPUT_PATH']
    result = runner.run(request(command: cmd))
    expect(result.output_json).to eq("from" => "file")
  end

  it "returns invalid_output when the command writes garbage" do
    result = runner.run(request(command: %q[sh -c 'echo not-json > $PROUTER_OUTPUT_PATH']))
    expect(result.error_type).to eq("invalid_output")
  end

  it "returns output_too_large when output.json exceeds the cap" do
    ENV["PROUTERD_MAX_OUTPUT_BYTES"] = "10"
    result = runner.run(request(command: %q[sh -c 'printf 12345678901 > $PROUTER_OUTPUT_PATH']))
    expect(result.error_type).to eq("output_too_large")
  ensure
    ENV.delete("PROUTERD_MAX_OUTPUT_BYTES")
  end

  it "returns non_zero_exit when the command fails" do
    result = runner.run(request(command: %q[sh -c 'echo nope >&2; exit 7']))
    expect(result.error_type).to eq("non_zero_exit")
    expect(result.exit_code).to eq(7)
  end

  # Failed blocks preserve any structured payload they emitted before
  # bailing — operator can see what the block produced via `show run`/
  # `show logs`. Downstream context propagation stays gated on success
  # in BlockExecutor so this only affects the persisted step row.
  it "preserves stdout JSON on non-zero exit" do
    result = runner.run(request(command: %q[sh -c 'echo "{\"partial\":true,\"reason\":\"crash\"}"; exit 9']))
    expect(result.error_type).to eq("non_zero_exit")
    expect(result.exit_code).to eq(9)
    expect(result.output_json).to eq("partial" => true, "reason" => "crash")
  end

  it "preserves an explicit output.json on non-zero exit" do
    result = runner.run(request(command: %q[sh -c 'echo "{\"phase\":\"loaded\"}" > $PROUTER_OUTPUT_PATH; exit 2']))
    expect(result.error_type).to eq("non_zero_exit")
    expect(result.output_json).to eq("phase" => "loaded")
  end

  it "leaves output_json nil on non-zero exit when stdout is plain log" do
    result = runner.run(request(command: %q[sh -c 'echo plain logs; exit 5']))
    expect(result.error_type).to eq("non_zero_exit")
    expect(result.output_json).to be_nil
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

  it "does not collect symlinks from $PROUTER_ARTIFACTS_DIR" do
    cmd = %q[sh -c 'echo "{}" > $PROUTER_OUTPUT_PATH; ln -s /etc/passwd $PROUTER_ARTIFACTS_DIR/leak']
    result = runner.run(request(command: cmd))
    expect(result.success?).to be(true)
    expect(result.artifacts.map(&:name)).not_to include("leak")
  end
end
