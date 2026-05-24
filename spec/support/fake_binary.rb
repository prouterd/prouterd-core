# frozen_string_literal: true

require "tempfile"

# Shared helper for tests that need to spawn a fake CLI binary that
# emits canned JSONL lines on stdout and exits with a configured
# code. Mirrors the helper inline in spec/prouterd/iface/llm_subprocess_spec.rb
# so the "extra" coverage specs can reuse the same shape without
# repeating the shell-quote dance.
module FakeBinaryHelper
  def fake_binary(jsonl_lines, exit_code: 0)
    f = Tempfile.create(["fake-llm-", ".sh"])
    f.write("#!/bin/sh\n")
    jsonl_lines.each { |l| f.write("printf '%s\\n' #{fb_shell_quote(l)}\n") }
    f.write("exit #{exit_code}\n")
    f.close
    File.chmod(0o755, f.path)
    f.path
  end

  def fb_shell_quote(text)
    "'#{text.gsub("'", "'\\\\''")}'"
  end
end

RSpec.configure do |c|
  c.include FakeBinaryHelper
end
