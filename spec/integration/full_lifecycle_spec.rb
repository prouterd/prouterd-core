require "spec_helper"
require "stringio"
require "tempfile"
require "prouterd/cli/main"

# End-to-end integration: walk the whole user journey through the public CLI
# surface — apply a config, trigger a run, replay, rollback. Mostly uses the
# stub runner so the test stays deterministic; the dedicated docker_e2e
# scripts cover the real-Docker path.
RSpec.describe "Full lifecycle integration" do
  let(:db_file) { Tempfile.create(["prouterd-lifecycle-", ".sqlite3"]).tap(&:close).path }
  after { File.delete(db_file) if File.exist?(db_file) }

  def run_cli(*argv, stdin: "")
    out = StringIO.new
    # The integration spec asserts on the human-format strings ("Run …",
    # "Replayed …", "Status: …") — Phase 36d's machine_output? would
    # flip stdout to JSON otherwise.
    out.define_singleton_method(:tty?) { true }
    err = StringIO.new
    code = Prouterd::CLI::Main.run(
      argv,
      stdin: StringIO.new(stdin),
      stdout: out, stderr: err
    )
    [code, out.string, err.string]
  end

  def write_pipeline(path, body)
    File.write(path, body)
  end

  it "apply -> trigger -> show run -> replay -> rollback round-trip" do
    Tempfile.create(["pipe-", ".prc"]) do |prc|
      prc.write(<<~PRC)
        router demo
        exit
        queue default
         concurrency 4
         timeout 1m
        exit
        interface manual cli
         no shutdown
        exit
        interface docker img1
         image alpine:latest
        exit
        process pipeline
         queue default
         block extract
          interface docker img1
         exit
         block enrich
          interface docker img1
         exit
         route extract enrich
        exit
        route interface cli process pipeline
        exit
      PRC
      prc.flush

      # 1. apply -> commit 1
      code, out, _err = run_cli("apply", prc.path, "--db", db_file)
      expect(code).to eq(0)
      expect(out).to match(/commit 1/)

      # 2. show commits via the read-only shell
      code, out, _err = run_cli("shell", "--db", db_file, stdin: "enable\nshow commits\nexit\n")
      expect(code).to eq(0)
      expect(out).to match(/^1\s+\w+/)

      # 3. trigger via stub runner — make the trigger event
      Tempfile.create(["evt-", ".json"]) do |evt|
        evt.write('{"body":{"name":"Acme"}}')
        evt.flush

        code, out, _err = run_cli(
          "trigger", "process", "pipeline", "input", evt.path,
          "--db", db_file, "--runner", "stub"
        )
        expect(code).to eq(0)
        expect(out).to include("success")
        expect(out).to include("extract")
        expect(out).to include("enrich")
      end

      # 4. show runs / show run
      code, out, _ = run_cli("shell", "--db", db_file, stdin: "enable\nshow runs\nexit\n")
      run_uid = out.lines.find { |l| l =~ /\Arun_\w+/ }&.split&.first
      expect(run_uid).to match(/\Arun_/)

      code, out, _ = run_cli("shell", "--db", db_file, stdin: "enable\nshow run #{run_uid}\nexit\n")
      expect(code).to eq(0)
      expect(out).to include("Status: success")

      # 5. replay
      code, out, _ = run_cli("replay", "run", run_uid, "--db", db_file, "--runner", "stub")
      expect(code).to eq(0)
      expect(out).to include("Replayed #{run_uid}")
      expect(out).to include("success")

      # 6. add a second commit, then rollback to commit 1
      Tempfile.create(["pipe2-", ".prc"]) do |prc2|
        prc2.write(<<~PRC)
          router demo
          exit
          queue default
           concurrency 8
           timeout 1m
          exit
          interface manual cli
           no shutdown
          exit
          interface docker img1
           image alpine:latest
          exit
          process pipeline
           queue default
           block extract
            interface docker img1
           exit
          exit
          route interface cli process pipeline
          exit
        PRC
        prc2.flush

        code, _out, _err = run_cli("apply", prc2.path, "--db", db_file)
        expect(code).to eq(0)
      end

      code, out, _err = run_cli("shell", "--db", db_file, stdin: "enable\nrollback commit 1\nexit\n")
      expect(code).to eq(0)
      expect(out).to include("Rolled back")

      # Running config should reflect commit 1 again (queue concurrency 4).
      code, out, _err = run_cli("shell", "--db", db_file, stdin: "enable\nshow running-config\nexit\n")
      expect(out).to include("concurrency 4")
    end
  end
end
