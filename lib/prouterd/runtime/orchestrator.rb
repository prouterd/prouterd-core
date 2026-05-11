# frozen_string_literal: true

require "json"
require "time"
require "set"
require "thread"
require "timeout"

module Prouterd
  module Runtime
    class TriggerError < StandardError; end

    # Drives a process from trigger to completion.
    #
    # Execution model (Phase 4 + Phase 5):
    #   * Walk the block DAG starting at entry blocks (no incoming routes).
    #   * Run all blocks at the same DAG level concurrently via threads.
    #   * After each block succeeds, evaluate every outgoing route's match
    #     condition; queue downstream blocks where conditions pass.
    #   * Multiple incoming routes were rejected at config parse time, so a
    #     block becomes ready as soon as its single predecessor's route fires.
    #   * On block failure: wait for the current level to drain, mark the run
    #     failed, do not enqueue further levels.
    #
    # Concurrency:
    #   * @db_mutex serializes DB writes (SQLite WAL allows concurrent reads
    #     but only one writer; running 5 blocks in parallel through Docker is
    #     I/O-bound and benefits from threading regardless).
    #   * @context_mutex guards the shared Context (read for input, write
    #     after output). Blocks at the same level write to disjoint output
    #     paths by design, so contention is brief.
    #
    # The orchestrator depends only on small abstractions (Runner, ArtifactStore,
    # Repositories::Runs) so unit tests stub the Runner cleanly.
    class Orchestrator
      attr_reader :runs

      # `runner` is a single runner (typically `Runner::CallRunner` in
      # production, `Runner::StubRunner` in tests). Per-block dispatch by
      # interface type happens inside CallRunner — the orchestrator
      # itself is dispatch-agnostic.
      def initialize(db:, runner:, artifact_store: nil, secret_resolver: nil,
                     logger: Prouterd::NullLogger.new,
                     max_parallelism: 8, in_flight: nil, metrics: nil,
                     events: Prouterd::Events.default,
                     system_url: nil,
                     mcp_pool: nil)
        @db = db
        @runner = runner
        @runs = Storage::Repositories::Runs.new(db)
        @artifact_store = artifact_store || ArtifactStore.new
        @secret_resolver = secret_resolver || EnvSecretResolver.new
        @logger = logger
        @max_parallelism = max_parallelism
        @in_flight = in_flight
        @metrics = metrics
        @events = events
        @system_url = system_url
        @mcp_pool = mcp_pool
        @retry_engine = RetryEngine.new(runs: @runs)
        @block_executor = BlockExecutor.new(
          db: @db, runs: @runs, runner: @runner,
          artifact_store: @artifact_store, secret_resolver: @secret_resolver,
          events: @events, logger: @logger, mcp_pool: @mcp_pool,
          retry_engine: @retry_engine
        )
      end

      # Trigger a process. Returns the Run record after execution completes.
      #
      # `document` is the AST::Document to interpret the trigger against
      # (typically session.running_config or the running commit).
      # `commit_id` is the optional ID of the config commit pinning the run.
      # `replay_of_run_id` is set when replaying an existing run so the
      # lineage can be queried (`show run` references it as "replay of <uid>").
      def trigger(document, process_name, input_event:, interface_name: nil,
                  commit_id: nil, replay_of_run_id: nil)
        run = enqueue(
          document, process_name,
          input_event: input_event,
          interface_name: interface_name,
          commit_id: commit_id,
          replay_of_run_id: replay_of_run_id
        )
        execute_run(run, document)
      end

      # Create the Run row WITHOUT executing it. Used by the webhook handler
      # so it can return a run_id to the client immediately and let a worker
      # thread drive execution. Returns the persisted Run.
      def enqueue(document, process_name, input_event:, interface_name: nil,
                  commit_id: nil, replay_of_run_id: nil)
        process = document.processes.find { |p| p.name == process_name }
        raise TriggerError, "no such process '#{process_name}'" unless process

        thread_id = resolve_thread_id(process, input_event)

        run = @runs.create_run(
          process_name: process_name,
          process_config_commit_id: commit_id,
          interface_name: interface_name,
          input_event: input_event,
          replay_of_run_id: replay_of_run_id,
          thread_id: thread_id
        )

        # Snapshot the live MCP tools/list at trigger time so replay
        # can detect drift (server upgraded between trigger and replay).
        # Single source of truth: per-iface descriptor list. Stored
        # only when the process actually uses MCP tools — keeps the
        # run row small for the common case.
        snapshot = capture_mcp_snapshot(process, document)
        if snapshot && !snapshot.empty?
          @runs.update_run(run.id, mcp_tools_json: JSON.dump(snapshot))
        end

        @events.publish(:run_created, run: run)
        run
      end

      def capture_mcp_snapshot(process, _document)
        return nil unless @mcp_pool

        ifaces = process.blocks.flat_map(&:mcp_refs).uniq
        return nil if ifaces.empty?

        @mcp_pool.tool_snapshot(ifaces)
      end

      # Resolve the process's `thread-id` template against the input event.
      # Templating uses the same scope shape as block call-fields, but only
      # `event.*` is meaningful here (no run/secret context yet). An empty
      # rendered string is treated as nil so an absent field doesn't pin
      # all runs to thread_id="".
      def resolve_thread_id(process, input_event)
        return nil unless process.thread_id_template

        rendered = Prouterd::Util::Templater.render(
          process.thread_id_template,
          { "event" => input_event || {} }
        )
        rendered = rendered.to_s.strip
        rendered.empty? ? nil : rendered
      end

      # Execute a previously-enqueued Run against a Document. Returns the
      # final Run row after termination. Safe to call from a worker thread.
      #
      # `from_block:` and `seed_context:` together support replay-from-block:
      # caller supplies the context that fed into the chosen block (taken
      # from an earlier run's step.input_json["context"]) and the orchestrator
      # starts execution AT that block instead of from entry blocks.
      def execute_run(run, document, from_block: nil, seed_context: nil)
        process = document.processes.find { |p| p.name == run.process_name }
        raise TriggerError, "no such process '#{run.process_name}'" unless process

        if from_block
          unless process.block(from_block)
            raise TriggerError, "no such block '#{run.process_name}/#{from_block}'"
          end
          execute(run, process, document, seed_context: seed_context, start_blocks: [from_block])
        else
          execute(run, process, document)
        end
      end

      # Resume a paused run with the supplied JSON value (defaults to {}).
      # Finalises the paused step with the value as its output, seeds the
      # run context with `<paused_block.name> => value`, and re-enters
      # the executor at the blocks immediately downstream of the paused
      # block. Idempotent only when the run is currently paused.
      def resume_run(run_uid, document, value: nil)
        run = @runs.get_run_by_uid(run_uid)
        raise TriggerError, "no such run '#{run_uid}'" unless run
        unless run.status == "paused"
          raise TriggerError, "run '#{run_uid}' is not paused (status=#{run.status})"
        end

        process = document.processes.find { |p| p.name == run.process_name }
        raise TriggerError, "process '#{run.process_name}' is not in the supplied document" unless process

        paused_step = @runs.list_steps(run.id).reverse.find { |s| s.status == "paused" }
        raise TriggerError, "run '#{run_uid}' has no paused step row" unless paused_step

        block = process.block(paused_step.block_name)
        unless block && block.pause?
          raise TriggerError,
                "paused step references block '#{paused_step.block_name}' which is no longer a pause block"
        end

        output_json = value || {}
        now = Time.now.utc.iso8601(3)
        @runs.update_step(
          paused_step.id,
          status: "success",
          finished_at: now,
          duration_ms: 0,
          output_json: JSON.dump(output_json)
        )

        seed = JSON.parse(run.context_json || "{}")
        seed[block.name] = output_json
        @runs.update_run(run.id, status: "running", context_json: JSON.dump(seed))
        @logger.notice("run resumed",
                       facility: "RUN", mnemonic: "RESUMED",
                       run_uid: run.uid, process: run.process_name,
                       block: block.name)

        downstream = downstream_blocks(process, block.name)
        if downstream.empty?
          finalize_run(run, status: "success")
          return @runs.get_run(run.id)
        end

        execute(run, process, document,
                seed_context: seed,
                start_blocks: downstream)
      end

      private

      def execute(run, process, document, seed_context: nil, start_blocks: nil)
        @in_flight&.register_run(run.uid)
        execute_inner(run, process, document, seed_context: seed_context, start_blocks: start_blocks)
      ensure
        @in_flight&.unregister_run(run.uid)
      end

      def execute_inner(run, process, document, seed_context: nil, start_blocks: nil)
        run_started_at = Time.now.utc
        running = @runs.update_run(run.id, status: "running", started_at: run_started_at.iso8601(3))
        @events.publish(:run_updated, run: running) if running

        # `system` carries daemon-scoped data templates can read — currently
        # `system.url` (the bind URL of the daemon process). Lets a block
        # template a self-pointing callback URL (`base-url
        # "{{system.url}}"`) without hardcoding host/port. Available to
        # both fresh runs and replay/resume seeds. Context.new deep-dups
        # and normalizes string vs symbol keys.
        context = Context.new(seed_context || {
          "event" => deep_stringify(run.input_event_json ? JSON.parse(run.input_event_json) : {})
        })
        context.set("system.url", @system_url) if @system_url

        # Per-run mutexes: DB writes serialized, context reads/writes guarded.
        db_mutex = Mutex.new
        ctx_mutex = Mutex.new
        # Per-run redactor scrubs secret values from log content before
        # they hit the DB. Empty when no secrets are declared.
        redactor = Redactor.from_document(document, @secret_resolver)

        ready = start_blocks || entry_blocks(process)
        if ready.empty?
          finalize_run(run, status: "failed", error: "process '#{process.name}' has no entry blocks")
          return @runs.get_run(run.id)
        end

        executed = Set.new
        failure_reason = nil
        # Per-block last ExecutionResult — needed by the cross-block
        # retry sweep so we can re-evaluate predicates against the
        # most recent attempt's output.
        block_results = {}
        # Per-block "outer retry" counter, separate from the inner
        # attempt counter inside execute_block_with_retries. Bounded
        # by the same retry_attempts cap; once a block has used its
        # cross-block-driven re-runs, further matches are ignored.
        outer_attempts = Hash.new(0)
        # Per-block overlay applied at the next execution (next outer
        # retry of that block). Carries cross-block feedback values
        # populated from `retry feedback <other_block>.<field> into
        # <var>` directives. Reset to nil after the block runs.
        outer_overlays = {}

        until ready.empty?
          # Soft-cancel: another shell may have stamped run.status=canceled.
          fresh = @runs.get_run(run.id)
          if fresh && fresh.status == "canceled"
            failure_reason = nil
            return finalize_canceled(run)
          end

          # Phase 35b: wall-clock timeout. cap = process.timeout || queue.timeout
          # || PROUTERD_RUN_DEFAULT_TIMEOUT_MS || 6h. Over-cap → kill in-flight
          # containers, finalize failed with error_type "run_timeout".
          if (overshoot = run_timeout_overshoot(process, document, run_started_at))
            log_system_safe(run, "run exceeded #{overshoot}ms wall-clock timeout", db_mutex)
            kill_in_flight_containers(run)
            return finalize_run(run, status: "failed",
                                     error: "run_timeout: exceeded #{overshoot}ms wall-clock timeout")
          end

          # Filter out shutdown / already-executed / skip-when-matched before
          # kicking off threads.
          level = []
          skipped = []
          paused_block = nil
          ready.each do |bn|
            next if executed.include?(bn)

            block = process.block(bn)
            unless block
              failure_reason = "block '#{bn}' is not defined"
              break
            end
            if block.shutdown
              executed << bn
              log_system_safe(run, "block '#{bn}' is shutdown; skipped", db_mutex)
              next
            end
            if block.pause?
              # Halt execution at this block. The run goes to status="paused"
              # until `prouter resume <run> [--value <json>]` injects an
              # output and re-enters this orchestrator at the downstream
              # blocks. Persist context so resume sees what's been built.
              paused_block = block
              break
            end
            if block.skip_when && skip_when_matches?(block, context, ctx_mutex)
              executed << bn
              record_skipped_block(run, block, context, ctx_mutex, db_mutex)
              skipped << block
              next
            end
            level << block
          end
          break if failure_reason
          if paused_block
            db_mutex.synchronize { update_run_context(run, context) }
            return finalize_run_paused(run, paused_block)
          end
          if level.empty? && skipped.empty?
            ready = []
            next
          end

          results = if level.empty?
                      []
                    else
                      run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex, redactor,
                                            outer_overlays: outer_overlays)
                    end
          level.each { |b| executed << b.name }
          results.each do |block_name, result|
            block_results[block_name] = result
            outer_overlays.delete(block_name)
          end

          # Persist accumulated context once after the level drains.
          db_mutex.synchronize { update_run_context(run, context) }

          # For failed blocks, consult the incoming route's on-failure policy.
          # `stop` (default) aborts the run; `continue` lets the run proceed
          # with remaining branches but the failed block's downstream is pruned.
          failed_blocks = []
          results.each do |block_name, result|
            next if result.success?

            failed_blocks << block_name
            policy = on_failure_for(process, block_name)
            if policy == "stop"
              raw = "block '#{block_name}' #{result.error_type || 'failed'}: " \
                    "#{result.error_message || "exit #{result.exit_code}"}"
              failure_reason = redactor.redact(raw)
            end
          end
          break if failure_reason

          # Build the next level: successfully completed blocks AND skipped
          # blocks both contribute downstream — a `skip-when` is a routing
          # pass-through, not a halt. Failed (no on-failure stop) blocks
          # have no output to feed.
          successful = level.reject { |b| failed_blocks.include?(b.name) } + skipped
          next_ready = []
          successful.each do |block|
            passing_routes = process.routes.select do |r|
              r.from_block == block.name && route_passes?(r, context, ctx_mutex)
            end
            passing_routes.each do |r|
              next if executed.include?(r.to_block) || next_ready.include?(r.to_block)

              next_ready << r.to_block
            end
          end

          # Cross-block retry sweep: a policy on block X may declare
          # `retry when Y.field eq "fail"` where Y is downstream of X.
          # Now that Y has run (and potentially other blocks too),
          # re-evaluate every completed block's policy against the
          # current run context. If any match AND the block's outer
          # retry budget isn't spent, schedule a re-execution: clear
          # context for X + everything downstream-reachable, drop them
          # from `executed`, prepend X to `next_ready`. Bounded by
          # policy.retry_attempts; bypassed entirely when no policy
          # references foreign-block paths.
          retriggered = @retry_engine.sweep_cross_block(
            process, document, block_results, executed, context, ctx_mutex,
            outer_attempts, outer_overlays
          )
          retriggered.each do |block_name|
            db_mutex.synchronize do
              @runs.append_log(
                run_id: run.id, stream: "system",
                content: "block '#{block_name}' re-triggered by cross-block retry-when (outer attempt " \
                         "#{outer_attempts[block_name]})"
              )
            end
            next_ready.unshift(block_name) unless next_ready.include?(block_name)
          end
          ready = next_ready
        end

        if failure_reason
          finalize_run(run, status: "failed", error: failure_reason)
        else
          finalize_run(run, status: "success")
        end
        @runs.get_run(run.id)
      end

      # Execute a level (a set of blocks ready to run concurrently) and
      # return [[block_name, ExecutionResult], ...] in arbitrary order. Each
      # entry includes the LAST attempt's result — retry history is in DB.
      def run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex, redactor,
                                outer_overlays: {})
        return [] if level.empty?

        if level.length == 1 || @max_parallelism <= 1
          return level.map do |block|
            [block.name, execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor,
                                                    outer_overlay: outer_overlays[block.name])]
          end
        end

        threads = level.map do |block|
          Thread.new do
            [block.name, execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor,
                                                    outer_overlay: outer_overlays[block.name])]
          end
        end
        threads.map(&:value)
      end

      # Per-block retry driver. Thin shim that owns the single-attempt work
      # and lets RetryEngine drive the loop. Each attempt creates its own
      # step row so the full retry history is queryable via show run / show
      # logs. Sleeps happen OUTSIDE both mutexes (the unlocked Kernel#sleep
      # lives in RetryEngine#run_with_retries).
      def execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor,
                                     outer_overlay: nil)
        @retry_engine.run_with_retries(
          run, process, block, context, document, db_mutex, ctx_mutex,
          outer_overlay: outer_overlay
        ) do |attempt, overlay|
          @block_executor.execute_single_attempt(
            run, process, block, attempt, context, document,
            db_mutex, ctx_mutex, redactor, template_overlay: overlay
          )
        end
      end

      def on_failure_for(process, block_name)
        # Block fails -> its incoming route's on-failure governs run fate.
        # Single-incoming is enforced at config time, so .find is exhaustive.
        # Entry blocks (no incoming) default to stop.
        incoming = process.routes.find { |r| r.to_block == block_name }
        return incoming.on_failure if incoming

        # Members of an all-best-effort parallel group don't have an
        # ordinary incoming route — they're entry blocks of the group's
        # parallel section. Their downstream route to the synthesized
        # barrier carries the join strategy's on-failure: respect it so
        # the run survives partial failure of the group.
        outgoing_to_barrier = process.routes.find do |r|
          r.from_block == block_name && barrier_block?(process, r.to_block)
        end
        return outgoing_to_barrier.on_failure if outgoing_to_barrier

        "stop"
      end

      def barrier_block?(process, name)
        block = process.blocks.find { |b| b.name == name }
        block && block.barrier?
      end

      def route_passes?(route, context, ctx_mutex)
        ctx_mutex.synchronize { MatchEvaluator.passes?(route.matches, context) }
      end

      def skip_when_matches?(block, context, ctx_mutex)
        ctx_mutex.synchronize { MatchEvaluator.evaluate(block.skip_when, context) }
      end

      # Persist a synthetic step row + seed context[block.name] so downstream
      # blocks can detect skip via {{block.skipped}} templating.
      def record_skipped_block(run, block, context, ctx_mutex, db_mutex)
        output = { "skipped" => true }
        now = Time.now.utc.iso8601(3)
        step = nil
        db_mutex.synchronize do
          step = @runs.create_step(
            run_id: run.id,
            block_name: block.name,
            attempt: 1,
            image: nil
          )
          @runs.update_step(
            step.id,
            status: "skipped",
            started_at: now,
            finished_at: now,
            duration_ms: 0,
            exit_code: nil,
            output_json: JSON.dump(output)
          )
        end
        ctx_mutex.synchronize { context.set(block.name, output) }
        log_system_safe(run, "block '#{block.name}' skipped (skip-when matched)", db_mutex)
        @events.publish(:step_updated, step: step, run_id: run.id, run_uid: run.uid) if step
      end

      def log_system_safe(run, message, db_mutex)
        db_mutex.synchronize { @runs.append_log(run_id: run.id, stream: "system", content: message) }
        @events.publish(:log_appended,
                        run_id:     run.id,
                        run_uid:    run.uid,
                        step_id:    nil,
                        stream:     "system",
                        content:    message,
                        created_at: Time.now.utc.iso8601(3))
      end

      def entry_blocks(process)
        with_incoming = process.routes.map(&:to_block).to_set
        process.blocks.reject { |b| with_incoming.include?(b.name) }.map(&:name)
      end

      def downstream_blocks(process, from_block)
        process.routes.select { |r| r.from_block == from_block }.map(&:to_block)
      end


      def update_run_context(run, context)
        @runs.update_run(run.id, context_json: JSON.dump(context.to_h))
      end

      def finalize_run(run, status:, error: nil)
        @metrics&.increment(:runs_total, process: run.process_name, status: status)
        finalized = @runs.update_run(
          run.id,
          status: status,
          finished_at: Time.now.utc.iso8601(3),
          error_summary: error
        )
        @events.publish(:run_updated, run: finalized) if finalized

        # Daemon-level run-completion log line. Per-run system_logs in
        # the DB carry the full timeline; this is the single line the
        # operator sees on stdout / `show logging` when grepping for
        # "what's recently failed".
        if finalized
          mnemonic = case status
                     when "success"   then "COMPLETED"
                     when "failed"    then "FAILED"
                     when "canceled"  then "CANCELED"
                     else                  "DONE"
                     end
          severity_method = (status == "failed") ? :error : :info
          @logger.public_send(
            severity_method, "run #{status}",
            facility: "RUN", mnemonic: mnemonic,
            run_uid: run.uid, process: run.process_name,
            duration_ms: finalized.duration_ms,
            error: error
          )
        end

        finalized
      end

      DEFAULT_RUN_TIMEOUT_MS = 6 * 60 * 60 * 1000 # 6 hours

      # Returns elapsed_ms when over the cap, nil otherwise. cap is
      # process.timeout_ms ?? queue.timeout_ms ?? env override ?? 6h.
      # Uses the local started-at captured at execute_inner entry, not
      # the DB row, so we don't have to refetch on every level.
      def run_timeout_overshoot(process, document, run_started_at)
        cap = process.timeout_ms
        if cap.nil? && process.queue_name
          queue = document.queues.find { |q| q.name == process.queue_name }
          cap = queue&.timeout_ms
        end
        cap ||= (ENV["PROUTERD_RUN_DEFAULT_TIMEOUT_MS"] || DEFAULT_RUN_TIMEOUT_MS).to_i
        return nil if cap <= 0

        elapsed_ms = ((Time.now.utc - run_started_at) * 1000).to_i
        elapsed_ms > cap ? elapsed_ms : nil
      end

      # Cap on the docker round-trip per container during a kill. The
      # daemon-side socket call is normally millisecond-fast, but a
      # docker daemon under pressure (or a torn-down socket) can hang
      # indefinitely. Without this cap, the orchestrator thread driving
      # the run-timeout sweep would itself wedge — exactly the scenario
      # the timeout machinery exists to prevent.
      KILL_DOCKER_TIMEOUT_SECONDS = 5

      # SIGTERM-then-SIGKILL every container the in-flight registry has
      # attached to this run. Used by Phase 35b run-timeout enforcement.
      def kill_in_flight_containers(run)
        return unless @in_flight && Runner::DockerRunner.docker_available?

        @in_flight.container_ids_for(run.uid).each do |cid|
          Timeout.timeout(KILL_DOCKER_TIMEOUT_SECONDS) do
            container = Docker::Container.get(cid)
            Runner::DockerStop.force_stop(container)
          end
        rescue Timeout::Error
          @logger.warn("docker kill timed out",
                       facility: "RUN", mnemonic: "KILL_TIMEOUT",
                       run_uid: run.uid, container: cid,
                       seconds: KILL_DOCKER_TIMEOUT_SECONDS)
        rescue StandardError
          # best-effort; orphan-container sweep on next boot will catch
          # anything we miss.
        end
      end

      # Halt at a `pause` block: write a step row marking it paused, set
      # the run status to "paused", and surface a system log line for
      # observability. Resumed via `Orchestrator#resume_run` later.
      def finalize_run_paused(run, block)
        now = Time.now.utc.iso8601(3)
        step = @runs.create_step(
          run_id: run.id,
          block_name: block.name,
          attempt: 1,
          image: nil
        )
        @runs.update_step(
          step.id,
          status: "paused",
          started_at: now,
          input_json: JSON.dump("pause_reason" => block.pause_reason)
        )
        log_system(run, "block '#{block.name}' paused: #{block.pause_reason}")
        paused = @runs.update_run(
          run.id,
          status: "paused"
        )
        @logger.notice("run paused",
                       facility: "RUN", mnemonic: "PAUSED",
                       run_uid: run.uid, process: run.process_name,
                       block: block.name, reason: block.pause_reason)
        @events.publish(:run_updated, run: paused) if paused
        @events.publish(:step_updated, step: step, run_id: run.id, run_uid: run.uid) if step
        paused
      end

      def finalize_canceled(run)
        # The cancel command already stamped run.status; we keep that and
        # just return the row. Don't overwrite finished_at — the cancel
        # command set it the moment the operator hit cancel.
        canceled = @runs.get_run(run.id)
        @events.publish(:run_updated, run: canceled) if canceled
        canceled
      end

      def log_system(run, message)
        @runs.append_log(run_id: run.id, stream: "system", content: message)
      end

      def deep_stringify(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then value.map { |v| deep_stringify(v) }
        else            value
        end
      end

    end

    # Resolves a secret reference into a runtime value. Two sources are
    # supported out of the box:
    #
    #   `source env <NAME>` — reads from the daemon's environment.
    #   `source file <path>` — reads the file's contents (trimmed of
    #       trailing newlines so a value cleanly drops into `KEY=VALUE`
    #       env vars). Useful for Docker/Compose secrets which mount at
    #       /run/secrets/<name>, and for Kubernetes secret volumes.
    #
    # Vault / AWS Secrets Manager / GCP Secret Manager: add a new resolver
    # class with a `#resolve(secret)` method and inject it via the
    # `secret_resolver:` constructor kwarg.
    class EnvSecretResolver
      def resolve(secret)
        case secret.source_type
        when "env"  then ENV[secret.source_value]
        when "file" then read_secret_file(secret.source_value)
        else raise TriggerError, "unsupported secret source '#{secret.source_type}'"
        end
      end

      def read_secret_file(path)
        return nil unless path && !path.empty?
        return nil unless File.file?(path)

        # Trailing newlines are a frequent gotcha — `echo "tok" > /run/secrets/x`
        # writes 4 bytes, of which one is "\n" that should NOT be part of
        # the bearer token. Trim once on read.
        File.read(path).chomp
      rescue SystemCallError
        nil
      end
    end
  end
end
