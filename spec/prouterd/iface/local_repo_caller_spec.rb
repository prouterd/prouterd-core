require "spec_helper"
require "tmpdir"
require "fileutils"

# Phase 37l: `interface local_repo` caller — whitelisted, sandboxed,
# read-only access to git checkouts.
RSpec.describe Prouterd::Iface::LocalRepoCaller do
  let(:caller_instance) { described_class.new }

  # Build a tiny repo on disk for end-to-end tests.
  def make_repo(root, name)
    repo_dir = File.join(root, name)
    FileUtils.mkdir_p(repo_dir)
    FileUtils.cd(repo_dir) do
      system("git init -q -b main", out: File::NULL, err: File::NULL)
      system("git config user.email a@b") || (raise "git config failed")
      system("git config user.name x")    || (raise "git config failed")
      File.write("README.md", "hello\nTODO(release-blocker): wire X\n")
      system("git add . && git commit -q -m 'initial'") || (raise "git commit failed")
    end
    repo_dir
  end

  def build_request(type_fields)
    Prouterd::Runner::RunRequest.new(
      run_uid: "run_x", process_name: "p", block_name: "b",
      execution_type: "local_repo", attempt: 1,
      env: {}, input_json: {}, timeout_ms: 5_000,
      type_fields: type_fields, staged_inputs: {}
    )
  end

  it "rejects a repo not in the whitelist" do
    Dir.mktmpdir do |root|
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "read",
        "repo" => "evil", "path" => "x"
      ))
      expect(result.error_type).to eq("not_whitelisted")
    end
  end

  it "rejects path traversal in the read call" do
    Dir.mktmpdir do |root|
      make_repo(root, "good")
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "read",
        "repo" => "good", "path" => "../etc/hosts"
      ))
      expect(result.error_type).to eq("path_traversal")
    end
  end

  it "reads a tracked file when the path resolves under the repo" do
    Dir.mktmpdir do |root|
      make_repo(root, "good")
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "read",
        "repo" => "good", "path" => "README.md"
      ))
      expect(result.error_type).to be_nil
      expect(result.output_json["path"]).to eq("README.md")
      expect(result.output_json["content"]).to include("hello")
    end
  end

  it "greps a pattern and returns a match list" do
    Dir.mktmpdir do |root|
      make_repo(root, "good")
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "grep",
        "repo" => "good", "pattern" => "TODO"
      ))
      expect(result.error_type).to be_nil
      matches = result.output_json["matches"]
      expect(matches).not_to be_empty
      expect(matches.first["file"]).to eq("README.md")
      expect(matches.first["text"]).to include("TODO")
    end
  end

  it "returns an empty match list when the grep pattern doesn't hit" do
    Dir.mktmpdir do |root|
      make_repo(root, "good")
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "grep",
        "repo" => "good", "pattern" => "ZZZ_NOT_THERE_ZZZ"
      ))
      expect(result.error_type).to be_nil
      expect(result.output_json["matches"]).to eq([])
    end
  end

  it "gathers commits with sha/author/timestamp/subject" do
    Dir.mktmpdir do |root|
      make_repo(root, "good")
      result = caller_instance.run(build_request(
        "root" => root, "whitelist" => "good", "call" => "gather",
        "repo" => "good", "default-branch" => "main"
      ))
      expect(result.error_type).to be_nil
      commits = result.output_json["commits"]
      expect(commits.length).to be >= 1
      expect(commits.first["subject"]).to eq("initial")
      expect(commits.first["sha"]).to match(/\A[a-f0-9]{40}\z/)
    end
  end
end
