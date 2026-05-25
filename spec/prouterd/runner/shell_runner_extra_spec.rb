require "spec_helper"
require "tempfile"
require "tmpdir"

RSpec.describe Prouterd::Runner::ShellRunner do
  let(:runner) { described_class.new }

  def request(command:, **opts)
    fields = { "exec" => command }
    fields["cwd"] = opts[:cwd] if opts.key?(:cwd)
    fields["env"] = opts[:custom_env] if opts.key?(:custom_env)
    fields["shell"] = opts[:shell] if opts.key?(:shell)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_test", process_name: "p", block_name: "b",
      execution_type: "shell", attempt: 1,
      env: opts[:env] || {}, input_json: opts[:input] || {},
      timeout_ms: opts[:timeout_ms], type_fields: fields,
      staged_inputs: opts[:staged_inputs] || {}
    )
  end

  describe "#parse_command" do
    it "uses default /bin/sh -c true when command is nil or empty" do
      expect(runner.send(:parse_command, nil, nil)).to eq(["/bin/sh", "-c", "true"])
      expect(runner.send(:parse_command, "", nil)).to eq(["/bin/sh", "-c", "true"])
    end

    it "honors a custom shell when supplied" do
      expect(runner.send(:parse_command, nil, "/bin/bash")).to eq(["/bin/bash", "-c", "true"])
    end

    it "shell-splits a regular command" do
      expect(runner.send(:parse_command, "echo hi", nil)).to eq(["echo", "hi"])
    end

    it "wraps in sh -c when Shellwords cannot parse" do
      expect(runner.send(:parse_command, %q{echo "unterminated}, "/bin/sh")).to eq(
        ["/bin/sh", "-c", %q{echo "unterminated}]
      )
    end
  end

  describe "#build_env" do
    it "merges custom env over the base env" do
      req = request(command: "true", env: { "A" => "1" }, custom_env: { "A" => "2", "B" => "3" })
      env = runner.send(:build_env, req, "/tmp/work")
      expect(env["A"]).to eq("2")
      expect(env["B"]).to eq("3")
    end

    it "overrides PROUTER_* paths to point at work_dir" do
      req = request(command: "true")
      env = runner.send(:build_env, req, "/tmp/work")
      expect(env["PROUTER_INPUT_PATH"]).to eq("/tmp/work/input.json")
      expect(env["PROUTER_OUTPUT_PATH"]).to eq("/tmp/work/output.json")
      expect(env["PROUTER_ARTIFACTS_DIR"]).to eq("/tmp/work/artifacts")
      expect(env["PROUTER_WORKDIR"]).to eq("/tmp/work")
    end

    it "rewrites PROUTER_INPUT_<NAME> env vars to host-side inputs/" do
      req = request(command: "true", staged_inputs: { "a.txt" => "/src" })
      env = runner.send(:build_env, req, "/tmp/work")
      expect(env["PROUTER_INPUT_A.TXT"]).to eq("/tmp/work/inputs/a.txt")
    end

    it "returns base env when no custom env Hash is provided" do
      req = request(command: "true", env: { "X" => "1" })
      env = runner.send(:build_env, req, "/tmp/work")
      expect(env["X"]).to eq("1")
    end
  end

  describe "#read_output_file" do
    it "translates SystemCallError into [false, nil, message]" do
      allow(Prouterd::Runner::IOLimits).to receive(:read_file).and_raise(Errno::EACCES.new("nope"))
      ok, raw, msg = runner.send(:read_output_file, "/tmp/x")
      expect(ok).to be(false)
      expect(raw).to be_nil
      expect(msg).to include("nope")
    end
  end

  describe "#extract_partial_output" do
    let(:work_dir) { Dir.mktmpdir("prouter-extract-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "prefers output.json with a Hash" do
      File.write(File.join(work_dir, "output.json"), '{"x":1}')
      expect(runner.send(:extract_partial_output, work_dir, "")).to eq("x" => 1)
    end

    it "accepts an Array from output.json" do
      File.write(File.join(work_dir, "output.json"), "[1,2]")
      expect(runner.send(:extract_partial_output, work_dir, "")).to eq([1, 2])
    end

    it "returns nil for a JSON scalar in output.json" do
      File.write(File.join(work_dir, "output.json"), "42")
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end

    it "returns nil when read_output_file fails" do
      File.write(File.join(work_dir, "output.json"), "anything")
      allow(runner).to receive(:read_output_file).and_return([false, nil, "boom"])
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end

    it "falls back to stdout when output.json is empty" do
      File.write(File.join(work_dir, "output.json"), "")
      expect(runner.send(:extract_partial_output, work_dir, '{"x":1}')).to eq("x" => 1)
    end

    it "falls back to stdout when output.json is unparseable" do
      File.write(File.join(work_dir, "output.json"), "garbage")
      expect(runner.send(:extract_partial_output, work_dir, '{"x":1}')).to eq("x" => 1)
    end

    it "returns nil when stdout is empty and no output.json" do
      expect(runner.send(:extract_partial_output, work_dir, "")).to be_nil
    end

    it "returns nil when stdout is plain log text" do
      expect(runner.send(:extract_partial_output, work_dir, "plain log\n")).to be_nil
    end
  end

  describe "#error_result" do
    it "builds a clean error envelope" do
      r = runner.send(:error_result, "boom", "bad")
      expect(r.error_type).to eq("boom")
      expect(r.error_message).to eq("bad")
      expect(r.exit_code).to be_nil
    end
  end

  describe "run with Errno::ENOENT (binary missing)" do
    it "returns shell_error envelope" do
      # parse_command will produce ["nope-cmd-doesnt-exist"]; popen3
      # raises ENOENT before any output.
      req = request(command: "/no/such/binary --arg")
      result = runner.run(req)
      expect(result.error_type).to eq("shell_error")
      expect(result.error_message).to match(/No such file|not found/i)
    end
  end

  describe "stage_inputs (private)" do
    let(:work_dir) { Dir.mktmpdir("prouter-stage-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "no-ops for nil / empty" do
      runner.send(:stage_inputs, work_dir, nil)
      runner.send(:stage_inputs, work_dir, {})
      expect(File.exist?(File.join(work_dir, "inputs"))).to be(false)
    end

    it "copies each staged source into inputs/<local>" do
      src = File.join(work_dir, "src.txt")
      File.write(src, "payload")
      runner.send(:stage_inputs, work_dir, { "a.txt" => src })
      expect(File.read(File.join(work_dir, "inputs", "a.txt"))).to eq("payload")
    end
  end

  describe "collect_artifacts edge cases" do
    let(:work_dir) { Dir.mktmpdir("prouter-art-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "returns [] when artifacts dir absent" do
      expect(runner.send(:collect_artifacts, work_dir)).to eq([])
    end
  end

  describe "terminate_process — KILL also gets ESRCH" do
    it "rescues ESRCH from Process.kill('KILL', ...) when both attempts find the pid gone" do
      fake = Class.new do
        def pid; 999_999; end
        def join(*); nil; end
      end.new
      # First TERM goes through, but the process exits before KILL fires.
      kill_calls = 0
      allow(Process).to receive(:kill) do |sig, _pid|
        kill_calls += 1
        raise Errno::ESRCH if sig == "KILL"
      end
      expect { runner.send(:terminate_process, fake) }.not_to raise_error
      expect(kill_calls).to eq(2)
    end
  end

  describe "classify_outcome: explicit empty output.json on success" do
    it "treats an empty output.json file as {} (mirrors the docker contract)" do
      req = request(
        command: %q[sh -c ': > $PROUTER_OUTPUT_PATH']
      )
      result = runner.run(req)
      expect(result.exit_code).to eq(0)
      expect(result.error_type).to be_nil
      expect(result.output_json).to eq({})
    end
  end

  describe "collect_artifacts SystemCallError rescue" do
    let(:work_dir) { Dir.mktmpdir("prouter-art-err-") }
    after { FileUtils.remove_entry(work_dir) if File.directory?(work_dir) }

    it "skips files whose lstat raises SystemCallError" do
      art_dir = File.join(work_dir, "artifacts")
      FileUtils.mkdir_p(art_dir)
      File.write(File.join(art_dir, "a.txt"), "x")
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(File.join(art_dir, "a.txt")).and_raise(Errno::EACCES.new("denied"))
      expect { runner.send(:collect_artifacts, work_dir) }.not_to raise_error
    end
  end

  describe "terminate_process is best-effort" do
    it "ignores Errno::ESRCH when the process is already dead" do
      fake = Class.new do
        def pid; 999_999; end
        def join(*); true; end
      end.new
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect { runner.send(:terminate_process, fake) }.not_to raise_error
    end

    it "escalates to KILL when TERM doesn't deliver in time" do
      fake = Class.new do
        def pid; 999_999; end
        def join(*); nil; end # never exits
      end.new
      received = []
      allow(Process).to receive(:kill) { |sig, _pid| received << sig }
      runner.send(:terminate_process, fake)
      expect(received).to include("TERM", "KILL")
    end
  end
end

RSpec.describe "Runner::ShellRunner collect_artifacts rel.empty? branch" do
  let(:runner) { Prouterd::Runner::ShellRunner.new }
  it "drops empty-rel entries from the listing" do
    Dir.mktmpdir do |work|
      art_dir = File.join(work, "artifacts")
      FileUtils.mkdir_p(art_dir)
      File.write(File.join(art_dir, "f.txt"), "x")
      # Override Dir.glob to inject the artifacts root itself as a yielded
      # path so the post-sub rel becomes "".
      original = Dir.method(:glob)
      allow(Dir).to receive(:glob) do |pattern, *args|
        paths = original.call(pattern, *args)
        paths.unshift(art_dir) # rel after sub("\A<art_dir>/?", "") is ""
        paths
      end
      result = runner.send(:collect_artifacts, work)
      expect(result.map(&:name)).to eq(["f.txt"])
    end
  end
end

RSpec.describe "Runner::ShellRunner terminate_process clean-exit branch" do
  let(:runner) { Prouterd::Runner::ShellRunner.new }
  it "captures the status when wait_thr.join(0) returns the thread (exited)" do
    fake = Class.new do
      def pid; 99_999_999; end
      def join(*args)
        # Pretend TERM made the process exit immediately.
        self
      end
      def value
        double(exitstatus: 0)
      end
    end.new
    allow(Process).to receive(:kill).with("TERM", any_args)
    runner.send(:terminate_process, fake)
  end
end

RSpec.describe "Runner::ShellRunner collect_artifacts dir-entry skip" do
  let(:runner) { Prouterd::Runner::ShellRunner.new }
  it "drops the artifacts root '.' entry (rel.empty? branch)" do
    Dir.mktmpdir do |work|
      FileUtils.mkdir_p(File.join(work, "artifacts"))
      File.write(File.join(work, "artifacts/x.txt"), "x")
      result = runner.send(:collect_artifacts, work)
      expect(result.map(&:name)).to eq(["x.txt"])
    end
  end
end
