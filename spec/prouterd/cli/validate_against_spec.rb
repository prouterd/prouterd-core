require "spec_helper"
require "prouterd/cli/main"
require "stringio"
require "tempfile"
require "json"

# Phase 36e CLI wiring spec.
RSpec.describe "Phase 36e prouter validate --against running" do
  def run_cli(*argv, tty: false)
    out = StringIO.new
    out.define_singleton_method(:tty?) { tty }
    err = StringIO.new
    code = Prouterd::CLI::Main.run(argv,
                                   stdin: StringIO.new,
                                   stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  let(:db) { Tempfile.create(["validate-", ".sqlite3"]).tap(&:close).path }
  after { File.delete(db) if File.exist?(db) }

  let(:base_prc) do
    p = Tempfile.create(["base-", ".prc"])
    p.write(<<~PRC)
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
    p.close
    p.path
  end
  after { File.delete(base_prc) if File.exist?(base_prc) }

  let(:changed_prc) do
    p = Tempfile.create(["changed-", ".prc"])
    p.write(<<~PRC)
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
      process q
       block b
        interface shell host
        exec "true"
       exit
      exit
      route interface cli process p
      exit
    PRC
    p.close
    p.path
  end
  after { File.delete(changed_prc) if File.exist?(changed_prc) }

  before do
    code, _ = run_cli("apply", base_prc, "--db", db, tty: true)
    expect(code).to eq(0)
  end

  it "reports no semantic changes when file matches running" do
    code, out, _ = run_cli("validate", base_prc, "--against", "running",
                           "--db", db, tty: true)
    expect(code).to eq(0)
    expect(out).to include("no semantic changes")
  end

  it "reports added process in human form when on TTY" do
    code, out, _ = run_cli("validate", changed_prc, "--against", "running",
                           "--db", db, tty: true)
    expect(code).to eq(0)
    expect(out).to include("processes added")
    expect(out).to include("q")
  end

  it "emits JSON when stdout is piped" do
    code, out, _ = run_cli("validate", changed_prc, "--against", "running",
                           "--db", db, tty: false)
    expect(code).to eq(0)
    payload = JSON.parse(out)
    expect(payload["total_changes"]).to eq(1)
    expect(payload["diff"]["processes_added"].first).to include("name" => "q", "kind" => "process")
  end
end
