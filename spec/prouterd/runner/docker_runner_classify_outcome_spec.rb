require "spec_helper"
require "tmpdir"
require "fileutils"

# Pure unit coverage for DockerRunner#classify_outcome — exercises the
# Phase 31 stdout-as-JSON path without booting a real container. Mirrors
# the ShellRunner behaviour so block authors can rely on the same rules
# regardless of which runner picks up the work.
RSpec.describe Prouterd::Runner::DockerRunner do
  let(:runner) { described_class.new }
  let(:work_dir) { Dir.mktmpdir("prouterd-classify-spec-") }
  after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

  def classify(exit_code:, stdout: "", output_file: nil)
    if output_file
      File.write(File.join(work_dir, "output.json"), output_file)
    end
    runner.send(:classify_outcome, work_dir, exit_code, stdout)
  end

  describe "non-zero exit" do
    # error_type still wins on the result envelope; the change is that
    # partial structured output the failing container emitted before
    # bailing is preserved on the step row so the operator can debug.
    # Downstream context propagation stays gated on success in
    # BlockExecutor — failed blocks still don't seed downstream
    # templating.
    it "preserves a JSON Hash captured from stdout" do
      err_type, err_msg, output = classify(exit_code: 7, stdout: '{"x":1}')
      expect(err_type).to eq("non_zero_exit")
      expect(err_msg).to include("7")
      expect(output).to eq("x" => 1)
    end

    it "preserves an explicit output.json over stdout" do
      _, _, output = classify(
        exit_code: 1,
        stdout: '{"from":"stdout"}',
        output_file: '{"from":"file"}'
      )
      expect(output).to eq("from" => "file")
    end

    it "returns nil when stdout is plain log lines" do
      _, _, output = classify(exit_code: 9, stdout: "TICK\nDone\n")
      expect(output).to be_nil
    end

    it "returns nil when stdout is empty" do
      _, _, output = classify(exit_code: 9, stdout: "")
      expect(output).to be_nil
    end
  end

  describe "with explicit /prouter/output.json" do
    it "parses a Hash" do
      _, _, output = classify(exit_code: 0, output_file: '{"score":85}')
      expect(output).to eq("score" => 85)
    end

    it "treats an empty file as {}" do
      _, _, output = classify(exit_code: 0, output_file: "")
      expect(output).to eq({})
    end

    it "surfaces invalid_output on malformed JSON" do
      err_type, err_msg, output = classify(exit_code: 0, output_file: "not-json")
      expect(err_type).to eq("invalid_output")
      expect(err_msg).to include("not valid JSON")
      expect(output).to be_nil
    end

    it "surfaces output_too_large when output.json exceeds the cap" do
      ENV["PROUTERD_MAX_OUTPUT_BYTES"] = "10"
      err_type, err_msg, output = classify(exit_code: 0, output_file: "12345678901")
      expect(err_type).to eq("output_too_large")
      expect(err_msg).to include("exceeds")
      expect(output).to be_nil
    ensure
      ENV.delete("PROUTERD_MAX_OUTPUT_BYTES")
    end

    it "ignores stdout when output.json is present" do
      _, _, output = classify(
        exit_code: 0,
        stdout: '{"from":"stdout"}',
        output_file: '{"from":"file"}'
      )
      expect(output).to eq("from" => "file")
    end
  end

  describe "without /prouter/output.json (stdout fallback)" do
    it "parses stdout as a Hash" do
      _, _, output = classify(exit_code: 0, stdout: '{"score":85}')
      expect(output).to eq("score" => 85)
    end

    it "parses stdout as an Array" do
      _, _, output = classify(exit_code: 0, stdout: "[1,2,3]")
      expect(output).to eq([1, 2, 3])
    end

    it "treats plain log lines as {}" do
      _, _, output = classify(exit_code: 0, stdout: "TICK at 12:00\nDone")
      expect(output).to eq({})
    end

    it "treats a JSON scalar (e.g. just '42') as {} — not useful as output" do
      _, _, output = classify(exit_code: 0, stdout: "42")
      expect(output).to eq({})
    end

    it "treats empty stdout as {} (side-effect-only block)" do
      _, _, output = classify(exit_code: 0, stdout: "")
      expect(output).to eq({})
    end
  end

  describe "artifact collection" do
    it "does not collect symlinks from /prouter/artifacts" do
      artifacts_dir = File.join(work_dir, "artifacts")
      FileUtils.mkdir_p(artifacts_dir)
      File.symlink("/etc/passwd", File.join(artifacts_dir, "leak"))

      artifacts = runner.send(:collect_artifacts, work_dir)

      expect(artifacts.map(&:name)).not_to include("leak")
    end
  end

  describe "streaming log capture" do
    it "caps streamed stdout without retaining docker-api's message stack" do
      fake_container = Class.new do
        def streaming_logs(**_opts)
          yield :stdout, "x" * 200_000
          yield :stderr, "warn"
        end
      end.new

      ENV["PROUTERD_LOG_CAPTURE_BYTES"] = "1000"
      out, err = runner.send(:capture_logs, fake_container)

      expect(out.bytesize).to be <= 1100
      expect(out).to include("truncated")
      expect(err).to eq("warn")
    ensure
      ENV.delete("PROUTERD_LOG_CAPTURE_BYTES")
    end
  end
end
