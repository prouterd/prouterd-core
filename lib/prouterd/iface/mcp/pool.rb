require_relative "session"
require_relative "server_command"

module Prouterd
  module Iface
    module Mcp
      # Process-singleton holder for one `Iface::Mcp::Session` per
      # `interface mcp <name>` declared in the running config. The
      # daemon owns the pool — it spawns at boot, restarts on config
      # apply, drains at shutdown.
      #
      # Sessions live for the lifetime of the daemon. Two agentic
      # blocks targeting `mcp atlassian` share one Session; each
      # call_tool gets its own JSON-RPC id, the Session de-multiplexes
      # responses (see Session#request).
      #
      # Health surface: per-iface state ∈ :starting | :ready |
      # :degraded | :stopped. `:degraded` means the session crashed
      # and we're between restart attempts (exponential backoff
      # capped at MAX_BACKOFF_SECONDS). `state_for(name)` is the
      # query API; the orchestrator's tool dispatcher uses it to
      # surface a clean `mcp_unavailable` error to the LLM rather
      # than blocking on a dead socket.
      class Pool
        STARTUP_HANDSHAKE_TIMEOUT = 15
        DEFAULT_TOOL_CALL_TIMEOUT_MS = 60_000
        BACKOFF_BASE_SECONDS = 1
        MAX_BACKOFF_SECONDS = 300
        RETRY_TICK_SECONDS = 1

        Entry = Struct.new(:iface_name, :session, :state, :tools, :last_error,
                           :next_retry_at, :backoff_seconds, keyword_init: true)

        def initialize(secret_resolver:, logger: NullLogger.new)
          @secret_resolver = secret_resolver
          @logger = logger
          @entries = {}              # iface_name => Entry
          @wanted = {}               # iface_name => [iface_ast, document]
          @entries_lock = Mutex.new
          @retry_thread = nil
          @stopping = false
        end

        # Spawn one Session per `interface mcp <name>` in `document`.
        # Idempotent: re-calling reconciles the pool against the
        # current document — sessions for removed interfaces are
        # stopped, new declarations get spawned. Existing sessions
        # whose argv/env/secret-set didn't change are kept hot.
        def start_or_reconcile(document)
          want = document.interfaces
                         .select { |i| i.type == "mcp" }
                         .each_with_object({}) { |i, h| h[i.name] = i }

          @entries_lock.synchronize do
            @wanted = want.transform_values { |iface| [iface, document] }
            (@entries.keys - want.keys).each do |gone|
              stop_entry(@entries[gone])
              @entries.delete(gone)
              @logger.info("mcp interface removed",
                           facility: "MCP", mnemonic: "REMOVED", iface: gone)
            end
          end

          want.each do |name, iface|
            spawn_or_keep(name, iface, document)
          end

          ensure_retry_thread
        end

        def stop
          @stopping = true
          @retry_thread&.join(2)
          @retry_thread = nil
          @entries_lock.synchronize do
            @entries.each_value { |e| stop_entry(e) }
            @entries.clear
            @wanted.clear
          end
        end

        # Snapshot the discovered tools for one or more mcp
        # interfaces. Used at trigger time to freeze the tool set
        # into the run row for later replay-drift detection.
        # Returns { iface_name => [tool_descriptor, ...] }.
        def tool_snapshot(iface_names)
          @entries_lock.synchronize do
            iface_names.each_with_object({}) do |name, h|
              entry = @entries[name]
              h[name] = entry && entry.state == :ready ? deep_dup(entry.tools) : []
            end
          end
        end

        # Tool dispatch. Looks up the namespaced name (`atlassian.search_issues`),
        # routes to the matching session, returns
        # `{ output_json: ... }` or `{ error_type:, error_message: }`.
        # Mirrors the shape orchestrator.build_tool_dispatcher returns
        # for non-mcp tools.
        def call_tool(namespaced_name, input, timeout_ms: nil)
          ns, tool = namespaced_name.split(".", 2)
          if tool.nil? || tool.empty?
            return { error_type: "bad_tool_name",
                     error_message: "expected '<iface>.<tool>', got '#{namespaced_name}'" }
          end

          entry = @entries_lock.synchronize { @entries[ns] }
          return mcp_unavailable(ns, "no such mcp interface") unless entry
          unless entry.state == :ready && entry.session
            return mcp_unavailable(ns, "session #{entry.state}: #{entry.last_error}")
          end

          unless entry.tools.any? { |t| t["name"] == tool }
            return { error_type: "unknown_tool",
                     error_message: "tool '#{namespaced_name}' is not advertised by the server " \
                                    "(server may have been upgraded; restart daemon to refresh tools/list)" }
          end

          timeout_seconds = ((timeout_ms || DEFAULT_TOOL_CALL_TIMEOUT_MS) / 1000.0)
          result = entry.session.call_tool(tool, input || {},
                                           timeout_seconds: timeout_seconds)
          { output_json: normalise_call_result(result) }
        rescue Session::TimeoutError => e
          { error_type: "timeout", error_message: e.message }
        rescue Session::CallError => e
          { error_type: "mcp_call_error", error_message: e.message }
        rescue Session::ClosedError => e
          mark_degraded(ns, e.message)
          mcp_unavailable(ns, e.message)
        end

        # `prouter show mcp` / web console health view.
        def health
          @entries_lock.synchronize do
            @entries.transform_values do |e|
              {
                state:      e.state,
                tools:      Array(e.tools).map { |t| t["name"] },
                last_error: e.last_error
              }
            end
          end
        end

        private

        def spawn_or_keep(name, iface, document)
          existing = @entries_lock.synchronize { @entries[name] }
          if existing && existing.state == :ready &&
             existing.session.alive? && config_unchanged?(existing, iface, document)
            return
          end

          # Stop stale before respawn.
          if existing
            @entries_lock.synchronize { stop_entry(existing) }
          end

          spawn_session(name, iface, document)
        end

        def spawn_session(name, iface, document)
          # Carry the previous entry's backoff_seconds forward so
          # repeated failures escalate (1s → 4s → 16s → ... → 300s).
          # Fresh spawns (no prior entry) start at BASE.
          previous = @entries_lock.synchronize { @entries[name] }
          inherited_backoff = previous&.backoff_seconds || BACKOFF_BASE_SECONDS

          server_field = iface.type_fields["server"]
          argv =
            begin
              ServerCommand.resolve(server_field)
            rescue ServerCommand::ResolveError => e
              return record_failure(name, iface, document, "server_unresolvable: #{e.message}")
            end

          env_static = (iface.type_fields["env"] || {}).dup
          env_secrets = resolve_secrets(iface.type_fields["secret"] || [], document)
          env = env_static.merge(env_secrets)
          cwd = iface.type_fields["cwd"]

          session = Session.new(argv: argv, env: env, cwd: cwd, logger: @logger)
          entry = Entry.new(iface_name: name, session: session, state: :starting,
                            tools: [], last_error: nil,
                            next_retry_at: nil, backoff_seconds: inherited_backoff)
          @entries_lock.synchronize { @entries[name] = entry }

          begin
            session.start
            session.initialize_handshake(timeout_seconds: STARTUP_HANDSHAKE_TIMEOUT)
            tools = session.list_tools(timeout_seconds: STARTUP_HANDSHAKE_TIMEOUT)
            @entries_lock.synchronize do
              entry.state = :ready
              entry.tools = tools
              entry.last_error = nil
              entry.backoff_seconds = BACKOFF_BASE_SECONDS
              entry.next_retry_at = nil
            end
            @logger.info("mcp interface ready",
                         facility: "MCP", mnemonic: "READY",
                         iface: name, tools: tools.map { |t| t["name"] })
          rescue Session::Error, StandardError => e
            entry.session = nil
            session.stop rescue nil
            mark_degraded(name, "#{e.class}: #{e.message}")
            tail = session.respond_to?(:stderr_tail) ? session.stderr_tail.last(5) : []
            @logger.error("mcp interface failed to start",
                          facility: "MCP", mnemonic: "START_FAILED",
                          iface: name, error: e.class.name, message: e.message,
                          stderr_tail: tail)
          end
        end

        def stop_entry(entry)
          return unless entry

          entry.state = :stopped
          entry.session&.stop
          entry.session = nil
        end

        def mark_degraded(iface_name, error_message)
          @entries_lock.synchronize do
            entry = @entries[iface_name]
            return unless entry

            entry.state = :degraded
            entry.last_error = error_message
            entry.session = nil
            entry.next_retry_at = Time.now + entry.backoff_seconds
            entry.backoff_seconds = [entry.backoff_seconds * 4, MAX_BACKOFF_SECONDS].min
          end
        end

        def record_failure(name, _iface, _document, message)
          entry = Entry.new(iface_name: name, session: nil, state: :degraded,
                            tools: [], last_error: message,
                            next_retry_at: Time.now + BACKOFF_BASE_SECONDS,
                            backoff_seconds: BACKOFF_BASE_SECONDS)
          @entries_lock.synchronize { @entries[name] = entry }
          @logger.error("mcp interface unresolvable",
                        facility: "MCP", mnemonic: "UNRESOLVABLE",
                        iface: name, message: message)
        end

        # Background tick: scan @entries for :degraded ones whose
        # `next_retry_at` has come due and the iface is still
        # wanted (in @wanted), and retry a spawn. Exponential
        # backoff per-entry, bounded by MAX_BACKOFF_SECONDS.
        # Started by `start_or_reconcile` and joined by `stop`.
        def ensure_retry_thread
          return if @retry_thread&.alive?

          @retry_thread = Thread.new do
            loop do
              break if @stopping

              tick
              sleep RETRY_TICK_SECONDS
            end
          rescue StandardError => e
            @logger.error("mcp retry thread crashed",
                          facility: "MCP", mnemonic: "RETRY_CRASH",
                          error: e.class.name, message: e.message)
          end
        end

        def tick
          # Snapshot due-now degraded entries under the lock; respawn
          # outside the lock so a slow Open3.popen3 doesn't block
          # call_tool / health.
          due = @entries_lock.synchronize do
            @entries.values.select do |e|
              e.state == :degraded &&
                e.next_retry_at &&
                Time.now >= e.next_retry_at &&
                @wanted.key?(e.iface_name)
            end.map(&:iface_name)
          end

          due.each do |name|
            iface, document = @entries_lock.synchronize { @wanted[name] }
            next unless iface

            @logger.info("mcp interface retry",
                         facility: "MCP", mnemonic: "RETRY",
                         iface: name)
            spawn_session(name, iface, document)
          end
        end

        # Pool keeps the original iface struct on the entry so we can
        # short-circuit reconciliation if the spec didn't change.
        # Kept simple: signature is server-spec + cwd + env + secret list.
        def config_unchanged?(_existing, _iface, _document)
          # v0: always reconcile by stopping + respawning if reconcile is
          # called. (Fast enough; agentic blocks aren't constant.)
          # A future Phase can compare the signature and keep hot.
          false
        end

        def resolve_secrets(names, document)
          names.each_with_object({}) do |secret_name, h|
            secret = document.secrets.find { |s| s.name == secret_name }
            next unless secret

            value = @secret_resolver.resolve(secret).to_s
            h[secret_name] = value
          end
        end

        def mcp_unavailable(iface, why)
          { error_type: "mcp_unavailable",
            error_message: "mcp interface '#{iface}' is unavailable: #{why}" }
        end

        # Convert MCP `content` array to a single output_json the
        # agentic loop can hand to the model. Single-text content
        # → parse-as-JSON-or-fall-back-to-text. Multiple / non-text →
        # full structure preserved.
        def normalise_call_result(result)
          content = Array(result["content"])
          if content.length == 1 && content.first.is_a?(Hash) && content.first["type"] == "text"
            text = content.first["text"].to_s
            parsed = (JSON.parse(text) rescue nil)
            return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

            return { "text" => text }
          end
          { "content" => content, "isError" => result["isError"] }
        end

        def deep_dup(obj)
          JSON.parse(JSON.dump(obj))
        end
      end
    end
  end
end
