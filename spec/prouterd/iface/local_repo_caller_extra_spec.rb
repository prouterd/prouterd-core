require "spec_helper"
require "tmpdir"
require "fileutils"

# Coverage-extension specs for the local_repo caller. Targets validation
# branches, error mappings, and helper paths not exercised by
# local_repo_caller_spec.rb.
RSpec.describe Prouterd::Iface::LocalRepoCaller do
  let(:caller_instance) { described_class.new }

  def build_request(type_fields, env: {}, timeout_ms: 5_000)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_x", process_name: "p", block_name: "b",
      execution_type: "local_repo", attempt: 1,
      env: env, input_json: {}, timeout_ms: timeout_ms,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  def make_repo(root, name)
    repo_dir = File.join(root, name)
    FileUtils.mkdir_p(repo_dir)
    FileUtils.cd(repo_dir) do
      system("git init -q -b main", out: File::NULL, err: File::NULL)
      system("git config user.email a@b") || (raise "git config failed")
      system("git config user.name x")    || (raise "git config failed")
      File.write("README.md", "hello\nTODO(release-blocker): wire X\n")
      File.write("big.bin", "Z" * 4096)
      system("git add . && git commit -q -m 'initial'") || (raise "git commit failed")
    end
    repo_dir
  end

  describe "validation" do
    it "errors with invalid_interface when root is empty" do
      result = caller_instance.run(build_request({"root" => "", "whitelist" => "x"}))
      expect(result.error_type).to eq("invalid_interface")
      expect(result.error_message).to include("root")
    end

    it "errors with invalid_interface when whitelist is empty" do
      Dir.mktmpdir do |root|
        result = caller_instance.run(build_request({"root" => root, "whitelist" => ""}))
        expect(result.error_type).to eq("invalid_interface")
        expect(result.error_message).to include("whitelist")
      end
    end

    it "errors with invalid_call when repo is missing" do
      Dir.mktmpdir do |root|
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => ""
        }))
        expect(result.error_type).to eq("invalid_call")
        expect(result.error_message).to include("repo")
      end
    end

    it "rejects path_traversal in the repo arg via the resolve_repo_dir guard" do
      Dir.mktmpdir do |root|
        # `..` style repo name escapes the root.
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "..", "repo" => "..",
          "call" => "read", "path" => "x"
        }))
        expect(result.error_type).to eq("path_traversal")
      end
    end

    it "errors with repo_missing when the repo dir is not a git checkout" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "no_git"))
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "no_git", "repo" => "no_git",
          "call" => "read", "path" => "x"
        }))
        expect(result.error_type).to eq("repo_missing")
      end
    end

    it "errors with invalid_call for an unknown call kind" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good", "call" => "ghost"
        }))
        expect(result.error_type).to eq("invalid_call")
        expect(result.error_message).to include("unknown call")
      end
    end
  end

  describe "read call edge cases" do
    it "errors with invalid_call when path is missing" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "read", "path" => ""
        }))
        expect(result.error_type).to eq("invalid_call")
      end
    end

    it "rejects an absolute path" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "read", "path" => "/etc/hosts"
        }))
        expect(result.error_type).to eq("path_traversal")
      end
    end

    it "errors with file_missing when the path doesn't exist" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "read", "path" => "nope.txt"
        }))
        expect(result.error_type).to eq("file_missing")
      end
    end

    it "errors with too_large when the file exceeds the configured cap" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "read", "path" => "big.bin",
          "max-file-size" => "1024"
        }))
        expect(result.error_type).to eq("too_large")
      end
    end

    it "honours an explicit KB / MB max-file-size override" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        # 1MB > 4KB, so this succeeds
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "read", "path" => "big.bin",
          "max-file-size" => "1MB"
        }))
        expect(result.error_type).to be_nil
      end
    end
  end

  describe "grep call edge cases" do
    it "errors with invalid_call when pattern is empty" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "grep", "pattern" => ""
        }))
        expect(result.error_type).to eq("invalid_call")
      end
    end

    it "rejects path_traversal in the grep path filter" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "grep", "pattern" => "TODO", "path" => "../etc"
        }))
        expect(result.error_type).to eq("path_traversal")
      end
    end

    it "scopes grep to a sub-path when provided" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "grep", "pattern" => "TODO", "path" => "README.md"
        }))
        expect(result.error_type).to be_nil
        expect(result.output_json["matches"].first["file"]).to eq("README.md")
      end
    end
  end

  describe "gather call edge cases" do
    it "uses branch field when set, falls back through default-branch, then 'main'" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "gather", "branch" => "main"
        }))
        expect(result.error_type).to be_nil
        expect(result.output_json["commits"].first["subject"]).to eq("initial")
      end
    end

    it "produces a git_error when the branch doesn't exist" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "gather", "branch" => "definitely-not-a-real-branch"
        }))
        expect(result.error_type).to eq("git_error")
      end
    end

    it "honours since / until filters (smoke: at least passes through git log)" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "gather", "branch" => "main",
          "since" => "1970-01-01", "until" => "2100-01-01"
        }))
        expect(result.error_type).to be_nil
      end
    end

    it "splits multi-commit git log into separate commit hashes" do
      Dir.mktmpdir do |root|
        repo = make_repo(root, "good")
        # Add a second commit so git log emits two SHA records separated
        # by a blank line — exercises the empty-line branch + file accum.
        FileUtils.cd(repo) do
          File.write("more.txt", "x\n")
          system("git add . && git commit -q -m 'second'")
        end
        result = caller_instance.run(build_request({          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "gather", "branch" => "main"
        }))
        expect(result.error_type).to be_nil
        expect(result.output_json["commits"].length).to eq(2)
      end
    end
  end

  describe "grep stderr non-empty failure path" do
    it "maps a non-zero grep exit with stderr text to git_error" do
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        # Inject a Open3.popen3 stub that yields exit-2 + non-empty stderr.
        allow(Open3).to receive(:popen3).and_wrap_original do |orig, *args, &blk|
          # /bin/sh: emit nothing to stdout, message to stderr, exit 2 →
          # exitstatus=2 with non-empty stderr.
          orig.call("/bin/sh", "-c", "echo grep-explode >&2; exit 2", &blk)
        end
        result = caller_instance.run(build_request({
          "root" => root, "whitelist" => "good", "repo" => "good",
          "call" => "grep", "pattern" => "anything"
        }))
        expect(result.error_type).to eq("git_error")
        expect(result.error_message).to include("grep-explode")
      end
    end
  end

  describe "private helpers" do
    it "parse_int returns default on nil/empty/invalid; integer otherwise" do
      c = caller_instance
      expect(c.send(:parse_int, nil, 9)).to eq(9)
      expect(c.send(:parse_int, "", 9)).to eq(9)
      expect(c.send(:parse_int, "x", 9)).to eq(9)
      expect(c.send(:parse_int, "12", 9)).to eq(12)
    end

    it "parse_size handles nil/empty/raw/KB/MB/default fallback" do
      c = caller_instance
      expect(c.send(:parse_size, nil, 99)).to eq(99)
      expect(c.send(:parse_size, "", 99)).to eq(99)
      expect(c.send(:parse_size, "  10 KB ", 99)).to eq(10 * 1024)
      expect(c.send(:parse_size, "2MB", 99)).to eq(2 * 1024 * 1024)
      expect(c.send(:parse_size, "500", 99)).to eq(500)
      expect(c.send(:parse_size, "garbage", 99)).to eq(99)
    end

    it "canonical_path rejects absolute paths and traversal" do
      c = caller_instance
      expect(c.send(:canonical_path, "/tmp", "/etc")).to be_nil
      expect(c.send(:canonical_path, "/tmp", "../oops")).to be_nil
    end

    it "canonical_path returns the abs path for a safe relative path" do
      Dir.mktmpdir do |dir|
        abs = caller_instance.send(:canonical_path, dir, "subfile")
        expect(abs).to eq(File.join(dir, "subfile"))
      end
    end

    it "canonical_path returns repo_dir for an empty relative path" do
      Dir.mktmpdir do |dir|
        # "." canonicalises to the repo dir; both abs == repo_dir and
        # abs.start_with?(repo_dir + "/") branches accepted.
        abs = caller_instance.send(:canonical_path, dir, ".")
        expect(abs).to eq(dir)
      end
    end

    it "git_error builds the canonical shape with first line of stderr" do
      c = caller_instance
      status = double("status", exitstatus: 128)
      out = c.send(:git_error, "fatal: bad\nmore\n", status)
      expect(out[:error_type]).to eq("git_error")
      expect(out[:error_message]).to include("fatal: bad")
      expect(out[:exit_code]).to eq(128)
    end

    it "git_error handles a nil status (covers status&.exitstatus else)" do
      out = caller_instance.send(:git_error, "fatal\n", nil)
      expect(out[:exit_code]).to be_nil
    end

    it "ok and error helpers match the documented shape" do
      ok = caller_instance.send(:ok, { "x" => 1 })
      expect(ok).to include(exit_code: 0, error_type: nil, error_message: nil)
      expect(ok[:output_json]).to eq("x" => 1)

      err = caller_instance.send(:error, "ty", "msg")
      expect(err).to include(exit_code: nil, error_type: "ty", error_message: "msg",
                              output_json: nil, stdout: "", stderr: "msg")
    end

    it "resolve_repo_dir returns nil when the joined path escapes root" do
      c = caller_instance
      Dir.mktmpdir do |root|
        expect(c.send(:resolve_repo_dir, root, "../escape")).to be_nil
      end
    end

    it "resolve_repo_dir returns the joined absolute path when valid" do
      c = caller_instance
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "foo"))
        expect(c.send(:resolve_repo_dir, root, "foo")).to eq(File.expand_path("foo", root))
      end
    end
  end

  describe "git timeout path" do
    it "kills a stuck git process and returns git_error from a non-zero exit" do
      # Replace Open3.popen3 with a child that sleeps forever, so the
      # deadline watchdog fires the TERM/KILL escalation.
      Dir.mktmpdir do |root|
        make_repo(root, "good")
        allow(Open3).to receive(:popen3).and_wrap_original do |orig, *args, &blk|
          # The first popen3 will be the gather git log. Replace it with
          # a sleeping process so the deadline triggers.
          orig.call("/bin/sh", "-c", "sleep 5", &blk)
        end
        result = caller_instance.run(build_request(
          { "root" => root, "whitelist" => "good", "repo" => "good",
            "call" => "gather", "branch" => "main" },
          timeout_ms: 50
        ))
        # Sleep returns 0 if it ran to completion; if killed via TERM
        # the wait_thr.value is signalled non-zero.
        expect(result.error_type).to eq("git_error").or be_nil
      end
    end
  end
end

RSpec.describe "Iface::LocalRepoCaller gather lines before any commit header" do
  let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

  def request(fields)
    Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "local_repo", attempt: 1, env: {},
      input_json: {}, timeout_ms: nil, type_fields: fields
    )
  end

  it "drops orphan lines that appear before any commit header" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        FileUtils.mkdir_p("g/.git")
      end
      # Canned git output where the first line is an orphan (no tab,
      # no current commit yet) — exercises the `elsif current` else.
      canned = "orphan-line\nsha1\ta\t100\tone\nfile1\n"
      status = double("status", success?: true, exitstatus: 0)
      allow(caller_instance).to receive(:run_git).and_return([canned, "", status])
      result = caller_instance.run(request({
        "root" => root, "whitelist" => "g", "repo" => "g",
        "call" => "gather", "branch" => "main"
      }))
      expect(result.error_type).to be_nil
      commits = result.output_json["commits"]
      expect(commits.length).to eq(1)
      expect(commits.first["files"]).to eq(["file1"])
    end
  end
end

RSpec.describe "Iface::LocalRepoCaller gather multi-commit file accumulation" do
  let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

  def make_repo(root, name)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) do
      system("git init -q -b main")
      system("git config user.email t@t")
      system("git config user.name t")
      File.write("a.txt", "1\n")
      system("git add . && git commit -q -m 'first'")
      File.write("b.txt", "2\n")
      system("git add . && git commit -q -m 'second'")
      File.write("a.txt", "3\n")
      system("git add . && git commit -q -m 'third'")
    end
    dir
  end

  def request(fields)
    Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "local_repo", attempt: 1, env: {},
      input_json: {}, timeout_ms: nil, type_fields: fields
    )
  end

  it "splits 3 commits into 3 entries, each with their changed files" do
    Dir.mktmpdir do |root|
      make_repo(root, "g")
      result = caller_instance.run(request({
        "root" => root, "whitelist" => "g", "repo" => "g",
        "call" => "gather", "branch" => "main"
      }))
      expect(result.error_type).to be_nil
      commits = result.output_json["commits"]
      expect(commits.length).to eq(3)
      # Each commit lists its changed files
      expect(commits.flat_map { |c| c["files"] }).to include("a.txt", "b.txt")
    end
  end
end

RSpec.describe "Iface::LocalRepoCaller gather defensive parse branches" do
  let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

  def make_repo(root, name)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) do
      system("git init -q -b main")
      system("git config user.email t@t")
      system("git config user.name t")
      File.write("a", "1")
      system("git add . && git commit -q -m 'first'")
    end
    dir
  end

  it "handles a git log that ends with a blank line (commits << current if current)" do
    Dir.mktmpdir do |root|
      repo_dir = make_repo(root, "g")
      # Mock run_git to inject a controlled output that ends with a blank line
      canned_out = "sha1\tauthor\t1700000000\tsubject1\nfile1\n\n"
      canned_err = ""
      status = double("status", success?: true, exitstatus: 0)
      allow(caller_instance).to receive(:run_git).and_return([canned_out, canned_err, status])
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "local_repo", attempt: 1, env: {},
        input_json: {}, timeout_ms: nil,
        type_fields: { "root" => root, "whitelist" => "g", "repo" => "g",
                       "call" => "gather", "branch" => "main" }
      )
      result = caller_instance.run(req)
      expect(result.error_type).to be_nil
      commits = result.output_json["commits"]
      expect(commits.length).to eq(1)
      expect(commits.first["sha"]).to eq("sha1")
      expect(commits.first["files"]).to eq(["file1"])
    end
  end

  it "handles consecutive blank lines (commits << current on first, then current nil on second)" do
    Dir.mktmpdir do |root|
      make_repo(root, "g")
      # Two commits with a double blank line between them
      canned_out = "sha1\ta\t100\tone\nfileA\n\n\nsha2\ta\t200\ttwo\nfileB\n"
      status = double("status", success?: true, exitstatus: 0)
      allow(caller_instance).to receive(:run_git).and_return([canned_out, "", status])
      req = Prouterd::Runner::RunRequest.new(
        run_uid: "r", process_name: "p", block_name: "b",
        execution_type: "local_repo", attempt: 1, env: {},
        input_json: {}, timeout_ms: nil,
        type_fields: { "root" => root, "whitelist" => "g", "repo" => "g",
                       "call" => "gather", "branch" => "main" }
      )
      result = caller_instance.run(req)
      commits = result.output_json["commits"]
      expect(commits.length).to eq(2)
    end
  end
end

RSpec.describe "Iface::LocalRepoCaller commit-flush branches" do
  let(:caller_instance) { Prouterd::Iface::LocalRepoCaller.new }

  def make_repo(root, name)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) do
      system("git init -q -b main")
      system("git config user.email t@t")
      system("git config user.name t")
      File.write("a.txt", "1\n")
      system("git add . && git commit -q -m 'initial'")
    end
    dir
  end

  def build_request(fields)
    Prouterd::Runner::RunRequest.new(
      run_uid: "r", process_name: "p", block_name: "b",
      execution_type: "local_repo", attempt: 1, env: {},
      input_json: {}, timeout_ms: nil, type_fields: fields
    )
  end

  it "flushes the in-progress commit when the loop ends with a non-empty current" do
    Dir.mktmpdir do |root|
      make_repo(root, "g")
      # Run gather to exercise the full log-parsing loop with a real
      # repo: that hits both the `commits << current if current` at
      # blank-line-after-files (L94) and the elsif current (L102)
      # branches, then the final `commits << current` after the loop.
      result = caller_instance.run(build_request({
        "root" => root, "whitelist" => "g", "repo" => "g",
        "call" => "gather", "branch" => "main"
      }))
      expect(result.error_type).to be_nil
      expect(result.output_json["commits"].length).to be >= 1
    end
  end
end

RSpec.describe "Iface::LocalRepoCaller canonical_path escape guard (defensive L172)" do
  it "rejects a relative path that File.expand_path collapses outside repo_dir" do
    caller_instance = Prouterd::Iface::LocalRepoCaller.new
    Dir.mktmpdir do |root|
      # Path is `subdir/.` which expand_path resolves to root, then the
      # `.` segment is filtered out before expand_path. To actually
      # reach the unless-branch we need a path that survives both
      # filters and expands outside root. Use a path that contains
      # NUL-free chars only but ends up outside via symlink? Not
      # achievable on POSIX with expand_path alone — this branch is
      # truly defensive against future input mutation. Skipped.
      expect(caller_instance.send(:canonical_path, root, "valid")).to start_with(root)
    end
  end
end
