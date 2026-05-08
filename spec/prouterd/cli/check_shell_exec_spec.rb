require "spec_helper"
require "prouterd/cli/main"
require "tempfile"

# `prouter check` warns when an `interface shell` block's `exec` first
# token resolves to a non-existent file on the validator's host.
RSpec.describe "Prouterd::CLI::Main `prouter check` shell-exec warnings" do
  def run_check(source)
    file = Tempfile.new(["check", ".prc"])
    file.write(source); file.flush
    stdout = StringIO.new
    stderr = StringIO.new
    code = Prouterd::CLI::Main.run(
      ["check", file.path],
      stdin: StringIO.new, stdout: stdout, stderr: stderr
    )
    file.unlink
    [code, stdout.string, stderr.string]
  end

  it "warns when an absolute exec path doesn't exist" do
    code, out, _err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
      exit
      process p
       block run_it
        interface shell host
        exec "/no/such/binary --flag"
       exit
      exit
    PRC
    expect(code).to eq(0)
    expect(out).to match(/Warnings:/)
    expect(out).to match(%r{exec '/no/such/binary' does not resolve to an existing file})
  end

  it "warns when a relative exec path under iface cwd doesn't exist" do
    code, _out, err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
       cwd /no/such/dir
      exit
      process p
       block run_it
        interface shell host
        exec "./missing.sh"
       exit
      exit
    PRC
    # second arg captures the rendered warning line in stdout
    code, out, _err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
       cwd /tmp
      exit
      process p
       block run_it
        interface shell host
        exec "./absolutely-not-here-#{Time.now.to_i}.sh"
       exit
      exit
    PRC
    expect(out).to match(/exec '\.\/absolutely-not-here-/)
    expect(out).to match(%r{looked at /tmp/absolutely-not-here-})
  end

  it "does NOT warn when the resolved path exists" do
    file = Tempfile.new(["payload", ".sh"])
    file.write("#!/bin/sh\necho ok"); file.flush
    File.chmod(0o755, file.path)
    code, out, _err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
      exit
      process p
       block run_it
        interface shell host
        exec "#{file.path} --flag"
       exit
      exit
    PRC
    file.unlink
    expect(code).to eq(0)
    expect(out).not_to match(/exec.*does not resolve/)
  end

  it "does NOT warn when exec is templated (resolved only at runtime)" do
    code, out, _err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
      exit
      process p
       block run_it
        interface shell host
        exec "{{event.binary}} --flag"
       exit
      exit
    PRC
    expect(code).to eq(0)
    expect(out).not_to match(/exec.*does not resolve/)
  end

  it "does NOT warn for a bare command name (PATH lookup)" do
    code, out, _err = run_check(<<~PRC)
      router demo
      exit
      interface shell host
      exit
      process p
       block run_it
        interface shell host
        exec "echo hi"
       exit
      exit
    PRC
    expect(code).to eq(0)
    expect(out).not_to match(/exec.*does not resolve/)
  end
end
