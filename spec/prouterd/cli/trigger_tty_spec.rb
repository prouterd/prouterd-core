require "spec_helper"
require "prouterd/cli/main"
require "stringio"
require "tempfile"
require "json"

# Phase 36d: `prouter trigger` (and replay) emit JSON when stdout is
# piped, human-friendly tables when on a TTY. Same payload schema
# across the two commands.
RSpec.describe "Phase 36d TTY autodetect" do
  def run_cli(*argv, tty: false, stdin_text: "")
    out = StringIO.new
    out.define_singleton_method(:tty?) { tty }
    err = StringIO.new
    code = Prouterd::CLI::Main.run(argv,
                                   stdin: StringIO.new(stdin_text),
                                   stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  let(:fixture) do
    fix = Tempfile.create(["fixture-", ".prc"])
    fix.write(<<~PRC)
      router demo
      exit
      interface manual cli
       no shutdown
      exit
      interface shell host
      exit
      process p
       block a
        interface shell host
        exec "true"
       exit
      exit
      route interface cli process p
      exit
    PRC
    fix.close
    fix.path
  end

  let(:db) { Tempfile.create(["test-", ".sqlite3"]).tap(&:close).path }

  before do
    code, _ = run_cli("apply", fixture, "--db", db, tty: true)
    expect(code).to eq(0)
  end

  let(:event) do
    e = Tempfile.create(["evt-", ".json"])
    e.write("{}")
    e.close
    e.path
  end

  it "emits JSON on stdout when stdout is not a TTY" do
    code, out, _ = run_cli("trigger", "process", "p", "input", event,
                           "--db", db, "--runner", "stub", tty: false)
    expect(code).to eq(0)

    payload = JSON.parse(out)
    expect(payload["run_id"]).to match(/\Arun_/)
    expect(payload["status"]).to eq("success")
    expect(payload["steps"].first).to include("block" => "a", "status" => "success")
  end

  it "emits the human table when stdout is a TTY" do
    code, out, _ = run_cli("trigger", "process", "p", "input", event,
                           "--db", db, "--runner", "stub", tty: true)
    expect(code).to eq(0)
    expect(out).to include("Run run_")
    expect(out).to include("success")
    # And it does NOT look like JSON.
    expect { JSON.parse(out.lines.first) }.to raise_error(JSON::ParserError)
  end

  after do
    File.delete(fixture) if File.exist?(fixture)
    File.delete(db) if File.exist?(db)
    File.delete(event) if File.exist?(event)
  end
end
