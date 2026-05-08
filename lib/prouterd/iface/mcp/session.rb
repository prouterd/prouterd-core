require "json"
require "open3"
require "monitor"
require "timeout"

module Prouterd
  module Iface
    module Mcp
      # Long-lived JSON-RPC 2.0 session against an MCP server
      # subprocess over stdio. Owns three pieces:
      #
      #   1. The subprocess (Open3.popen3 -> stdin/stdout/stderr/wait).
      #   2. A reader thread draining stdout, dispatching responses to
      #      callers waiting on a request id, queueing notifications.
      #   3. A request-id table (Hash<id, MonitorMixin condvar>) so
      #      concurrent agentic blocks can share one Session safely:
      #      `tools/call` from two threads gets two distinct ids and
      #      each thread waits on its own condvar.
      #
      # Lifecycle:
      #   sess = Session.new(argv:, env:, cwd:, logger:)
      #   sess.start                    # spawn + reader thread
      #   sess.initialize_handshake     # protocol handshake
      #   tools = sess.list_tools       # tools/list
      #   sess.call_tool(name, input, timeout_seconds: 30)
      #   sess.stop                     # graceful stop + reap
      #
      # Errors:
      #   StartError      — failed to spawn / handshake at start time
      #   CallError       — server returned a JSON-RPC error frame
      #   TimeoutError    — call_tool exceeded its timeout
      #   ClosedError     — session was stopped or subprocess exited
      class Session
        class Error        < StandardError; end
        class StartError   < Error; end
        class CallError    < Error
          attr_reader :code, :data
          def initialize(message, code: nil, data: nil)
            super(message)
            @code = code
            @data = data
          end
        end
        class TimeoutError < Error; end
        class ClosedError  < Error; end

        PROTOCOL_VERSION = "2024-11-05".freeze

        attr_reader :tools

        def initialize(argv:, env: {}, cwd: nil, logger: NullLogger.new,
                       client_name: "prouterd", client_version: Prouterd::VERSION)
          @argv = argv
          @env = env
          @cwd = cwd
          @logger = logger
          @client_name = client_name
          @client_version = client_version

          @id_counter = 0
          @id_mutex = Mutex.new
          # request id => { condvar: ConditionVariable, mutex: Mutex,
          #                  result: Hash | nil, error: CallError | nil,
          #                  done: bool }
          @waiters = {}
          @waiters_lock = Monitor.new

          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thread = nil
          @reader_thread = nil
          @stderr_thread = nil
          @stderr_tail = []   # last N stderr lines for crash diagnostics
          @stderr_cap = 100
          @closed = false
          @tools = []
        end

        # Spawn the subprocess + start the stdout reader thread. Does
        # NOT do the protocol handshake — call `initialize_handshake`
        # for that, so the caller can fold initialization errors into
        # its own error model.
        def start
          spawn_env = ENV.to_h.merge(@env.transform_keys(&:to_s))
          spawn_opts = {}
          spawn_opts[:chdir] = @cwd if @cwd && !@cwd.empty?

          begin
            @stdin, @stdout, @stderr, @wait_thread =
              Open3.popen3(spawn_env, *@argv, spawn_opts)
          rescue Errno::ENOENT, Errno::EACCES => e
            raise StartError, "spawn failed: #{e.class}: #{e.message}"
          end

          @stdin.binmode
          @stdout.binmode
          @stderr.binmode

          @reader_thread = Thread.new { reader_loop }
          @stderr_thread = Thread.new { stderr_loop }
          self
        end

        # MCP `initialize` -> `initialized` handshake. After this returns
        # the server is ready and `tools` is populated via list_tools.
        def initialize_handshake(timeout_seconds: 10)
          response = request("initialize", {
            "protocolVersion" => PROTOCOL_VERSION,
            "capabilities"    => { "tools" => {} },
            "clientInfo"      => {
              "name"    => @client_name,
              "version" => @client_version
            }
          }, timeout_seconds: timeout_seconds)

          # Per spec, the client MUST send `notifications/initialized`
          # after a successful `initialize`. No reply expected.
          notify("notifications/initialized", {})
          response
        end

        # tools/list — populates @tools with whatever the server
        # advertised. Returns the list. Format per MCP spec:
        # `{tools: [{name, description, inputSchema}, ...]}`.
        def list_tools(timeout_seconds: 10)
          response = request("tools/list", {}, timeout_seconds: timeout_seconds)
          @tools = Array(response["tools"])
        end

        # tools/call — dispatches to the server. Returns the raw
        # `content` array (the agentic loop normalises it to a string).
        # `is_error` flag in the response body is preserved by the
        # caller; we don't translate it to an exception here.
        def call_tool(name, arguments, timeout_seconds: 60)
          response = request("tools/call", {
            "name"      => name,
            "arguments" => arguments || {}
          }, timeout_seconds: timeout_seconds)
          response
        end

        def stop(grace_seconds: 5)
          return if @closed

          @closed = true
          # Best-effort `shutdown` notification before SIGTERM. Some
          # servers expect it to flush buffers.
          begin
            notify("shutdown", {}) if @stdin && !@stdin.closed?
          rescue StandardError
            # ignore — going down anyway
          end

          [@stdin, @stdout, @stderr].each do |io|
            io&.close
          rescue StandardError
            nil
          end

          # Wake any in-flight callers so they don't hang forever.
          @waiters_lock.synchronize do
            @waiters.each_value do |w|
              w[:mutex].synchronize do
                w[:error] = ClosedError.new("session stopped")
                w[:done] = true
                w[:condvar].signal
              end
            end
            @waiters.clear
          end

          if @wait_thread&.alive?
            pid = @wait_thread.pid
            begin
              Process.kill("TERM", pid)
            rescue Errno::ESRCH
              # already gone
            end
            deadline = Time.now + grace_seconds
            until !@wait_thread.alive? || Time.now > deadline
              sleep 0.05
            end
            if @wait_thread.alive?
              begin
                Process.kill("KILL", pid)
              rescue Errno::ESRCH
                nil
              end
              @wait_thread.join
            end
          end

          @reader_thread&.kill
          @stderr_thread&.kill
        end

        def alive?
          !@closed && @wait_thread&.alive?
        end

        def stderr_tail
          @stderr_tail.dup
        end

        private

        # Send a JSON-RPC request and block until the matching response
        # arrives or the timeout fires. Each call gets a fresh id; the
        # reader thread routes the response to the right waiter.
        def request(method, params, timeout_seconds:)
          raise ClosedError, "session is closed" if @closed

          id = next_id
          waiter = {
            mutex:   Mutex.new,
            condvar: ConditionVariable.new,
            result:  nil,
            error:   nil,
            done:    false
          }
          @waiters_lock.synchronize { @waiters[id] = waiter }

          frame = JSON.dump(
            "jsonrpc" => "2.0",
            "id"      => id,
            "method"  => method,
            "params"  => params || {}
          )
          begin
            @stdin.puts(frame)
            @stdin.flush
          rescue IOError, Errno::EPIPE => e
            cleanup_waiter(id)
            raise ClosedError, "subprocess stdin closed: #{e.class}: #{e.message}"
          end

          deadline = Time.now + timeout_seconds
          waiter[:mutex].synchronize do
            until waiter[:done]
              remaining = deadline - Time.now
              if remaining <= 0
                cleanup_waiter(id)
                raise TimeoutError, "no response to '#{method}' within #{timeout_seconds}s"
              end
              waiter[:condvar].wait(waiter[:mutex], remaining)
            end
          end
          @waiters_lock.synchronize { @waiters.delete(id) }

          raise waiter[:error] if waiter[:error]
          waiter[:result]
        end

        # Notifications are JSON-RPC frames without an `id` — fire and
        # forget, no response expected.
        def notify(method, params)
          frame = JSON.dump(
            "jsonrpc" => "2.0",
            "method"  => method,
            "params"  => params || {}
          )
          @stdin.puts(frame)
          @stdin.flush
        rescue IOError, Errno::EPIPE
          # session is going down; nothing useful to do
        end

        def next_id
          @id_mutex.synchronize { @id_counter += 1 }
        end

        def cleanup_waiter(id)
          @waiters_lock.synchronize { @waiters.delete(id) }
        end

        # Drain stdout line-by-line, parse each line as a JSON-RPC
        # frame, route to the waiter or log unmatched/notification.
        def reader_loop
          while (line = @stdout.gets)
            line.strip!
            next if line.empty?

            frame =
              begin
                JSON.parse(line)
              rescue JSON::ParserError => e
                @logger.warn("mcp non-JSON stdout",
                             facility: "MCP", mnemonic: "BAD_FRAME",
                             error: e.message, sample: line[0, 200])
                next
              end

            id = frame["id"]
            if id
              dispatch_response(id, frame)
            else
              # notification from server; we don't act on these in v0
              # but log so operators see things like
              # `notifications/tools/list_changed`.
              method = frame["method"]
              @logger.debug("mcp notification",
                            facility: "MCP", mnemonic: "NOTIFY",
                            method: method)
            end
          end
        rescue IOError
          # subprocess closed stdout
        end

        def dispatch_response(id, frame)
          waiter = @waiters_lock.synchronize { @waiters[id] }
          return unless waiter

          if frame["error"].is_a?(Hash)
            err_body = frame["error"]
            err = CallError.new(err_body["message"].to_s,
                                code: err_body["code"], data: err_body["data"])
            waiter[:mutex].synchronize do
              waiter[:error] = err
              waiter[:done] = true
              waiter[:condvar].signal
            end
          else
            waiter[:mutex].synchronize do
              waiter[:result] = frame["result"] || {}
              waiter[:done] = true
              waiter[:condvar].signal
            end
          end
        end

        def stderr_loop
          while (line = @stderr.gets)
            line = line.chomp
            @stderr_tail << line
            @stderr_tail.shift if @stderr_tail.length > @stderr_cap
            @logger.debug("mcp stderr",
                          facility: "MCP", mnemonic: "STDERR",
                          line: line[0, 500])
          end
        rescue IOError
          # subprocess closed stderr
        end
      end
    end
  end
end
