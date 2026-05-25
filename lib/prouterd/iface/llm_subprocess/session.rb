# frozen_string_literal: true

require "open3"

module Prouterd
  module Iface
    module LlmSubprocess
      # Shared subprocess machinery for codex_cli / claude_cli spawns —
      # both the synchronous LlmSubprocess.call path AND the agentic
      # multi-turn loop in Iface::LlmAgentic. Owns the boilerplate
      # they share:
      #
      #   * popen3 with the right options hash (cwd / unsetenv_others)
      #   * a watchdog thread that kills the process on deadline expiry
      #   * a stderr reader thread that force-tags UTF-8 and accumulates
      #     into a single buffer
      #
      # Callers run their own stdin/stdout loop inside the `run` block;
      # the Session disappears when the block returns and reports the
      # spawn outcome (status / accumulated stderr / timed-out flag).
      class Session
        # `value` is whatever the block returned (stdout_lines for the
        # synchronous path; the agentic loop's outcome for LlmAgentic).
        Result = Struct.new(:value, :status, :stderr_text, :timed_out, keyword_init: true)

        DEFAULT_TIMEOUT_MS = 120_000

        # Exposed to the block as the third yield arg. Lets the caller
        # observe live stderr / timeout state without reaching into
        # Session internals.
        class Handle
          def initialize(stderr_buf:, timed_out_ref:)
            @stderr_buf    = stderr_buf
            @timed_out_ref = timed_out_ref
          end

          def stderr_buf; @stderr_buf; end
          def timed_out?; @timed_out_ref.call; end
        end

        def initialize(env:, argv:, timeout_ms:, cwd: nil, sandbox_env: false)
          @env        = env
          @argv       = argv
          @timeout_ms = timeout_ms || DEFAULT_TIMEOUT_MS
          @options    = LlmSubprocess.popen_options(cwd: cwd, sandbox_env: sandbox_env)
        end

        # Yields `(stdin, stdout, handle)` to the block. When the
        # deadline passes the watchdog SIGTERMs (then SIGKILLs) the
        # process, the pipes close, and any in-flight `stdout.each_line`
        # returns. Callers should check `handle.timed_out?` after their
        # read loop exits to distinguish "subprocess finished normally"
        # from "we killed it on timeout".
        def run(&block)
          raise ArgumentError, "Session.run requires a block" unless block

          stderr_buf      = String.new(encoding: Encoding::UTF_8)
          timed_out_flag  = false
          deadline        = Time.now + (@timeout_ms / 1000.0)
          status          = nil
          block_value     = nil

          popen_args = @options.empty? ? [@env, *@argv] : [@env, *@argv, @options]
          Open3.popen3(*popen_args) do |stdin, stdout, stderr, wait_thr|
            err_thread = Thread.new do
              stderr_buf << LlmSubprocess.utf8_safe(stderr.read.to_s)
            end

            watchdog = Thread.new do
              loop do
                break unless wait_thr.alive?
                if Time.now > deadline
                  # Set the flag first: the kill causes stdout to EOF,
                  # which lets the block return and the session check the
                  # flag — possibly before the watchdog gets back here to
                  # assign it.
                  timed_out_flag = true
                  Process.kill("TERM", wait_thr.pid) rescue nil
                  sleep 0.05
                  Process.kill("KILL", wait_thr.pid) rescue nil
                  break
                end
                sleep 0.02
              end
            end

            handle = Handle.new(stderr_buf: stderr_buf, timed_out_ref: -> { timed_out_flag })

            begin
              block_value = block.call(stdin, stdout, handle)
            ensure
              # Block may have broken out early (agentic loop hits
              # max_turns). Closing stdin signals EOF so a well-behaved
              # subprocess can finish; the popen3 wait below still
              # picks up its real exit. Watchdog is asleep on a
              # bounded sleep, so killing the thread is safe.
              stdin.close rescue nil
              watchdog.kill if watchdog.alive?
              err_thread.join
            end

            status = timed_out_flag ? :timeout : wait_thr.value
          end

          Result.new(
            value:       block_value,
            status:      status,
            stderr_text: stderr_buf,
            timed_out:   timed_out_flag
          )
        end
      end
    end
  end
end
