# frozen_string_literal: true

require "open3"
require "json"
require_relative "caller_timing"

module Prouterd
  module Iface
    # Caller for `interface local_repo`. Read-only access to a
    # whitelisted set of git checkouts under a single root directory.
    #
    # Security:
    #   - `repo` MUST be exactly one of the whitelisted names.
    #   - the resolved repo directory MUST live directly under root.
    #   - any user-supplied `path` is canonicalised under the repo dir;
    #     traversal (`..`) is rejected.
    #   - subprocess invokes `git -C <repo>` with explicit argv (no shell
    #     interpolation) so user-influenced strings can't smuggle flags.
    #
    # We do not pull, fetch, or write — an external cron is expected
    # to keep the checkouts fresh.
    class LocalRepoCaller
      include CallerTiming

      DEFAULT_MAX_RESULTS = 50
      MAX_FILE_SIZE_DEFAULT = 500 * 1024 # 500 KB
      GIT_TIMEOUT_DEFAULT_MS = 30_000

      private

      def perform_run(request)
        root      = request.field("root").to_s
        whitelist = (request.field("whitelist") || "").split(",").map(&:strip).reject(&:empty?)
        return error("invalid_interface", "interface missing root") if root.empty?
        return error("invalid_interface", "interface missing whitelist") if whitelist.empty?

        repo = request.field("repo").to_s
        return error("invalid_call", "block missing 'repo'") if repo.empty?
        unless whitelist.include?(repo)
          return error("not_whitelisted", "repo '#{repo}' is not in the interface whitelist")
        end

        repo_dir = resolve_repo_dir(root, repo)
        unless repo_dir
          return error("path_traversal", "repo '#{repo}' escapes root '#{root}'")
        end
        unless File.directory?(repo_dir) && File.directory?(File.join(repo_dir, ".git"))
          return error("repo_missing", "repo dir '#{repo_dir}' is not a git checkout")
        end

        kind = request.field("call").to_s
        case kind
        when "gather" then run_gather(request, repo_dir)
        when "read"   then run_read(request, repo_dir)
        when "grep"   then run_grep(request, repo_dir)
        else
          error("invalid_call", "unknown call '#{kind}' (expected gather|read|grep)")
        end
      end

      def resolve_repo_dir(root, repo)
        # The whitelist entry is allowed to be either a flat name
        # ("vosio-app") or a slashed name ("vosio/app"). Canonicalise
        # the join and require the final dir to live under root.
        joined = File.expand_path(repo, File.expand_path(root))
        root_canon = File.expand_path(root)
        return nil unless joined == root_canon || joined.start_with?(root_canon + "/")

        joined
      end

      def run_gather(request, repo_dir)
        branch = (request.field("branch").to_s.empty? ? request.field("default-branch") : request.field("branch")) || "main"
        max = parse_int(request.field("max-results"), DEFAULT_MAX_RESULTS)
        since_arg = request.field("since")
        until_arg = request.field("until")

        argv = ["git", "-C", repo_dir, "log",
                "--max-count=#{max}",
                "--name-only",
                "--pretty=format:%H%x09%an%x09%at%x09%s",
                branch]
        argv += ["--since", since_arg] if since_arg && !since_arg.empty?
        argv += ["--until", until_arg] if until_arg && !until_arg.empty?

        out, err, status = run_git(argv, request.timeout_ms)
        return git_error(err, status) unless status.success?

        commits = []
        current = nil
        out.lines.each do |raw|
          line = raw.chomp
          if line.empty?
            commits << current if current
            current = nil
            next
          end
          if line.include?("\t") && current.nil?
            sha, author, ts, subject = line.split("\t", 4)
            current = { "sha" => sha, "author" => author, "timestamp" => ts.to_i,
                        "subject" => subject, "files" => [] }
          elsif current
            current["files"] << line
          end
        end
        commits << current if current

        ok({ "commits" => commits })
      end

      def run_read(request, repo_dir)
        rel = request.field("path").to_s
        return error("invalid_call", "block 'read' requires path") if rel.empty?

        abs = canonical_path(repo_dir, rel)
        return error("path_traversal", "path '#{rel}' escapes repo") unless abs

        unless File.file?(abs)
          return error("file_missing", "no such file '#{rel}' in repo")
        end

        cap = parse_size(request.field("max-file-size"), MAX_FILE_SIZE_DEFAULT)
        size = File.size(abs)
        if size > cap
          return error("too_large", "file '#{rel}' is #{size} bytes (cap #{cap})")
        end

        ok({
          "path"    => rel,
          "size"    => size,
          "content" => File.read(abs)
        })
      end

      def run_grep(request, repo_dir)
        pattern = request.field("pattern").to_s
        return error("invalid_call", "block 'grep' requires pattern") if pattern.empty?

        max = parse_int(request.field("max-results"), DEFAULT_MAX_RESULTS)
        rel_path = request.field("path").to_s

        argv = ["git", "-C", repo_dir, "grep",
                "-n", "--no-color", "--max-count=#{max}",
                "-E", "--", pattern]
        if !rel_path.empty?
          abs = canonical_path(repo_dir, rel_path)
          return error("path_traversal", "path '#{rel_path}' escapes repo") unless abs

          argv << rel_path
        end

        out, err, status = run_git(argv, request.timeout_ms)
        # `git grep` exits 1 on no matches — treat that as success-with-empty.
        if status.exitstatus == 1 && err.to_s.empty?
          return ok({ "matches" => [] })
        end
        return git_error(err, status) unless status.success?

        matches = out.lines.first(max).map do |raw|
          file, line_no, text = raw.chomp.split(":", 3)
          { "file" => file, "line" => line_no.to_i, "text" => text.to_s }
        end
        ok({ "matches" => matches })
      end

      def canonical_path(repo_dir, rel)
        # Reject absolute paths and any traversal segment.
        return nil if rel.start_with?("/")
        return nil if rel.split("/").any? { |seg| seg == ".." }

        abs = File.expand_path(rel, repo_dir)
        return nil unless abs == repo_dir || abs.start_with?(repo_dir + "/")

        abs
      end

      def run_git(argv, timeout_ms)
        deadline = Time.now + ((timeout_ms || GIT_TIMEOUT_DEFAULT_MS) / 1000.0)
        Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_buf = String.new(encoding: Encoding::UTF_8)
          err_buf = String.new(encoding: Encoding::UTF_8)
          out_thread = Thread.new { out_buf << stdout.read.to_s }
          err_thread = Thread.new { err_buf << stderr.read.to_s }
          while wait_thr.alive?
            if Time.now > deadline
              Process.kill("TERM", wait_thr.pid) rescue nil
              sleep 0.05
              Process.kill("KILL", wait_thr.pid) rescue nil
              break
            end
            sleep 0.02
          end
          out_thread.join
          err_thread.join
          return [out_buf, err_buf, wait_thr.value]
        end
      end

      def git_error(stderr, status)
        {
          exit_code:     status&.exitstatus,
          output_json:   nil,
          stdout:        "",
          stderr:        stderr.to_s,
          error_type:    "git_error",
          error_message: "git failed: #{stderr.to_s.lines.first.to_s.chomp}"
        }
      end

      def ok(output_json)
        {
          exit_code:     0,
          output_json:   output_json,
          stdout:        "",
          stderr:        "",
          error_type:    nil,
          error_message: nil
        }
      end

      def error(type, message)
        {
          exit_code:     nil,
          output_json:   nil,
          stdout:        "",
          stderr:        message,
          error_type:    type,
          error_message: message
        }
      end

      def parse_int(value, default)
        return default if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        Integer(value.to_s)
      rescue ArgumentError, TypeError
        default
      end

      def parse_size(value, default)
        return default if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        case value.to_s.strip
        when /\A(\d+)\s*KB\z/i then Regexp.last_match(1).to_i * 1024
        when /\A(\d+)\s*MB\z/i then Regexp.last_match(1).to_i * 1024 * 1024
        when /\A(\d+)\z/        then Regexp.last_match(1).to_i
        else default
        end
      end
    end
  end
end
