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

  it "non-zero exit beats everything else" do
    err_type, err_msg, output = classify(exit_code: 7, stdout: '{"x":1}')
    expect(err_type).to eq("non_zero_exit")
    expect(err_msg).to include("7")
    expect(output).to be_nil
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
end
