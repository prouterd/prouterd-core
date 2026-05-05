require "json"
require "time"
require "set"
require "thread"

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
                     events: Prouterd::Events.default)
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

        run = @runs.create_run(
          process_name: process_name,
          process_config_commit_id: commit_id,
          interface_name: interface_name,
          input_event: input_event,
          replay_of_run_id: replay_of_run_id
        )
        @events.publish(:run_created, run: run)
        run
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

      private

      def execute(run, process, document, seed_context: nil, start_blocks: nil)
        @in_flight&.register_run(run.uid)
        execute_inner(run, process, document, seed_context: seed_context, start_blocks: start_blocks)
      ensure
        @in_flight&.unregister_run(run.uid)
      end

      def execute_inner(run, process, document, seed_context: nil, start_blocks: nil)
        running = @runs.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))
        @events.publish(:run_updated, run: running) if running

        context = if seed_context
                    Context.new(seed_context)
                  else
                    Context.new("event" => deep_stringify(run.input_event_json ? JSON.parse(run.input_event_json) : {}))
                  end

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

        until ready.empty?
          # Soft-cancel: another shell may have stamped run.status=canceled.
          fresh = @runs.get_run(run.id)
          if fresh && fresh.status == "canceled"
            failure_reason = nil
            return finalize_canceled(run)
          end

          # Filter out shutdown / already-executed before kicking off threads.
          level = []
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
            level << block
          end
          break if failure_reason
          if level.empty?
            ready = []
            next
          end

          results = run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex, redactor)
          level.each { |b| executed << b.name }

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

          # Build the next level: ONLY successfully completed blocks contribute
          # downstream (failed-but-continue blocks have no output to feed).
          successful = level.reject { |b| failed_blocks.include?(b.name) }
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
      def run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex, redactor)
        return [] if level.empty?

        if level.length == 1 || @max_parallelism <= 1
          return level.map do |block|
            [block.name, execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor)]
          end
        end

        threads = level.map do |block|
          Thread.new do
            [block.name, execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor)]
          end
        end
        threads.map(&:value)
      end

      # Per-block retry driver. Each attempt creates its own step row so the
      # full retry history is queryable via show run / show logs. Sleeps
      # happen OUTSIDE both mutexes (with an unlocked Kernel#sleep).
      def execute_block_with_retries(run, process, block, context, document, db_mutex, ctx_mutex, redactor)
        policy = lookup_policy(document, block.retry_policy_name)
        attempt = 1
        result = nil
        previous_summary = nil

        loop do
          if attempt > 1
            delay_ms = RetryCalculator.delay_ms_before(policy, attempt)
            sleep(delay_ms / 1000.0) if delay_ms.positive?
            db_mutex.synchronize do
              @runs.append_log(
                run_id: run.id, stream: "system",
                content: "retrying block '#{block.name}' attempt #{attempt}/#{policy.retry_attempts} after #{delay_ms}ms backoff"
              )
            end
          end

          overlay = { "iteration" => attempt }
          overlay["previous"] = previous_summary if previous_summary

          result = execute_single_attempt(
            run, process, block, attempt, context, document,
            db_mutex, ctx_mutex, redactor, template_overlay: overlay
          )
          break if result.success?
          break unless RetryCalculator.more_attempts?(policy, attempt)
          break unless retry_when_passes?(policy, result, db_mutex, run, block)

          previous_summary = build_previous_summary(result, attempt)
          attempt += 1
        end

        result
      end

      # When a policy declares one or more `retry when` conditions, the failure
      # result must satisfy at least one for retry to proceed. No conditions
      # means "retry on any failure" (existing behaviour).
      def retry_when_passes?(policy, result, db_mutex, run, block)
        return true if policy.nil? || policy.retry_when_matches.empty?

        synthetic = {
          "error_type"    => result.error_type,
          "error_message" => result.error_message,
          "exit_code"     => result.exit_code
        }
        passes = policy.retry_when_matches.any? { |m| MatchEvaluator.evaluate(m, OverlayContext.new({}, synthetic)) }
        unless passes
          db_mutex.synchronize do
            @runs.append_log(
              run_id: run.id, stream: "system",
              content: "block '#{block.name}' failed with error_type=#{result.error_type.inspect} — no retry-when condition matched, treating as terminal"
            )
          end
        end
        passes
      end

      def build_previous_summary(result, attempt)
        {
          "attempt"       => attempt,
          "error_type"    => result.error_type,
          "error_message" => result.error_message,
          "exit_code"     => result.exit_code,
          "stdout"        => result.stdout.to_s,
          "stderr"        => result.stderr.to_s
        }
      end

      # Lightweight context wrapper for templating overlays. Falls through to
      # the underlying Runtime::Context for paths the overlay does not
      # provide. Used to expose `iteration`, `previous.*`, and `secret.*` to
      # templating without polluting the run-shared Context (which would
      # race across parallel block attempts).
      class OverlayContext
        def initialize(base, overlay)
          @base = base
          @overlay = overlay
        end

        def get(path)
          head, *rest = path.to_s.split(".")
          if @overlay.key?(head)
            return @overlay[head] if rest.empty?

            rest.reduce(@overlay[head]) do |acc, k|
              if acc.is_a?(Hash)
                acc[k]
              elsif acc.is_a?(Array) && k =~ /\A\d+\z/
                acc[k.to_i]
              else
                break nil
              end
            end
          elsif @base.respond_to?(:get)
            @base.get(path)
          end
        end
      end

      def lookup_policy(document, policy_name)
        return nil if policy_name.nil?

        document.policies.find { |p| p.name == policy_name }
      end

      def on_failure_for(process, block_name)
        # Block fails -> its incoming route's on-failure governs run fate.
        # Single-incoming is enforced at config time, so .find is exhaustive.
        # Entry blocks (no incoming) default to stop.
        incoming = process.routes.find { |r| r.to_block == block_name }
        incoming ? incoming.on_failure : "stop"
      end

      def route_passes?(route, context, ctx_mutex)
        ctx_mutex.synchronize { MatchEvaluator.passes?(route.matches, context) }
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

      # One attempt of one block. DB writes go through db_mutex; Context get
      # for input + set for output go through ctx_mutex. Runner.run() runs
      # OUTSIDE both — that's where the actual concurrency happens.
      def execute_single_attempt(run, process, block, attempt, context, document, db_mutex, ctx_mutex, redactor, template_overlay: nil)
        # Resolve `interface <type> <name>` reference to the AST::Interface
        # declared at top level. Validator already ensured this exists and
        # is outbound; defensive lookup here is just for runtime safety.
        ref = block.interface_ref
        unless ref
          return Runner::ExecutionResult.new(
            exit_code: nil, stdout: "", stderr: "",
            output_json: nil, artifacts: [],
            error_type: "invalid_block",
            error_message: "block '#{block.name}' has no `interface` directive",
            duration_ms: 0, started_at: nil, finished_at: nil
          )
        end
        iface = document.interfaces.find { |i| i.name == ref.name && i.type == ref.type }
        unless iface
          return Runner::ExecutionResult.new(
            exit_code: nil, stdout: "", stderr: "",
            output_json: nil, artifacts: [],
            error_type: "invalid_interface",
            error_message: "block '#{block.name}' references undeclared interface " \
                           "'#{ref.type} #{ref.name}'",
            duration_ms: 0, started_at: nil, finished_at: nil
          )
        end

        # Build per-run context payload — full context flows in, no slice.
        # Templating reads paths directly from this payload, plus a
        # per-attempt overlay (iteration, previous, secret) only visible
        # to this block-attempt. Both the interface body and the per-call
        # block fields go through templating so `dsn "{{secret.PG_DSN}}"`
        # on the interface and `path "/issue/{{event.key}}"` on the block
        # both work.
        overlay = (template_overlay || {}).merge("secret" => secret_overlay(document))
        scope = OverlayContext.new(context, overlay)
        input_payload = nil
        templated_iface_fields = nil
        templated_call_fields = nil
        ctx_mutex.synchronize do
          input_payload = build_input_payload(run, block, context)
          templated_iface_fields = templated_fields(iface.type_fields || {}, scope)
          templated_call_fields  = templated_fields(block.type_fields, scope)
        end

        step = nil
        running_step = nil
        db_mutex.synchronize do
          step = @runs.create_step(
            run_id: run.id,
            block_name: block.name,
            attempt: attempt,
            image: iface.type_fields["image"]
          )
          running_step = @runs.update_step(
            step.id,
            status: attempt == 1 ? "running" : "retrying",
            started_at: Time.now.utc.iso8601(3),
            input_json: JSON.dump(input_payload)
          )
          running_step = @runs.update_step(step.id, status: "running") if attempt > 1
        end
        @events.publish(:step_created, step: step,         run_id: run.id, run_uid: run.uid) if step
        @events.publish(:step_updated, step: running_step, run_id: run.id, run_uid: run.uid) if running_step

        staged_inputs = stage_artifact_inputs(run, block, db_mutex)

        env = build_env(run, process, block, iface, document)
        staged_inputs.each_key do |local_name|
          env["PROUTER_INPUT_#{local_name.upcase}"] = "/prouter/inputs/#{local_name}"
        end

        # Merge templated interface-config with per-call args. iface fields
        # are connection-level (base-url, image, dsn, cwd, ...), block
        # fields are call-specific (method, path, command, query, ...).
        # Both have already been templated; the call fields win on key
        # conflict so a block can override an interface default.
        merged_fields = templated_iface_fields.merge(templated_call_fields)
        request = Runner::RunRequest.new(
          run_uid: run.uid,
          process_name: process.name,
          block_name: block.name,
          execution_type: iface.type,
          attempt: attempt,
          env: env,
          input_json: input_payload,
          timeout_ms: block.timeout_ms,
          type_fields: merged_fields,
          staged_inputs: staged_inputs
        )

        result = @runner.run(request)

        # Verify every `produces <relpath>` declaration was actually written.
        # Failure here uses the same retry/on-failure machinery as any other
        # block error so existing escalation logic applies unchanged.
        if result.success? && !block.produces.empty?
          result = enforce_produces(block, result)
        end

        # Phase 14: enforce output contract if the block declares one.
        # A violation reshapes the result so the orchestrator's existing
        # retry / on-failure logic applies — we don't need a separate
        # parallel control flow.
        if result.success? && block.contract_name
          result = enforce_output_contract(block, document, result, run, step, db_mutex, redactor)
        end

        finished_step = nil
        db_mutex.synchronize do
          persist_logs(run, step, result, redactor)
          persist_artifacts(run, step, block, result)
          finished_step = @runs.update_step(
            step.id,
            status: result.to_step_status,
            finished_at: Time.now.utc.iso8601(3),
            duration_ms: result.duration_ms,
            exit_code: result.exit_code,
            error_type: result.error_type,
            error_message: redactor.redact(result.error_message),
            output_json: result.output_json ? JSON.dump(result.output_json) : nil
          )
        end
        @events.publish(:step_updated, step: finished_step, run_id: run.id, run_uid: run.uid) if finished_step

        if result.success?
          ctx_mutex.synchronize { update_context_with_output(block, context, result) }
        end

        result
      end

      # Look up archived artifacts the block declares as `input X from Y.Z`.
      # Returns Hash<local_name, host_path>. Validator already guarantees the
      # upstream block exists and produces the artifact; here we just resolve
      # to the row that was archived during this run. If the upstream step
      # was skipped or its archive is missing, we raise — the orchestrator's
      # outer rescue turns this into a normal block failure with retry.
      def stage_artifact_inputs(run, block, db_mutex)
        return {} if block.artifact_inputs.empty?

        rows = nil
        db_mutex.synchronize do
          rows = @runs.list_artifacts(run.id)
        end

        block.artifact_inputs.each_with_object({}) do |ai, acc|
          row = rows.find { |r| r.block_name == ai.from_block && r.name == ai.from_artifact }
          unless row
            raise TriggerError,
                  "block '#{block.name}': artifact '#{ai.from_block}.#{ai.from_artifact}' " \
                  "not found in run #{run.uid} (upstream block did not produce it)"
          end
          acc[ai.local_name] = row.path
        end
      end

      # Reshape a successful result into a "missing_artifact" failure if any
      # declared `produces <relpath>` is absent from the runner's output.
      def enforce_produces(block, result)
        produced = (result.artifacts || []).map(&:name).to_set
        missing = block.produces.reject { |p| produced.include?(p) }
        return result if missing.empty?

        message = "block did not produce declared artifact(s): #{missing.join(', ')}"
        Runner::ExecutionResult.new(
          exit_code: result.exit_code,
          stdout: result.stdout, stderr: result.stderr,
          output_json: nil,
          artifacts: result.artifacts,
          error_type: "missing_artifact",
          error_message: message,
          duration_ms: result.duration_ms,
          started_at: result.started_at, finished_at: result.finished_at
        )
      end

      # If the block has `contract <name>` declared, validate output against
      # the contract's requirements. Returns the (possibly mutated) result.
      #
      #   on violation fail   — rewrite to a contract_violation failure
      #   on violation retry  — same, but with retryable error_type so the
      #                          retry loop attempts again per the policy
      #   on violation warn   — keep as success, log warnings to system stream
      def enforce_output_contract(block, document, result, run, step, db_mutex, redactor)
        contract = document.contracts.find { |c| c.name == block.contract_name }
        return result unless contract # validator already errored; defensive

        violations = ContractValidator.validate(contract, result.output_json)
        return result if violations.empty?

        message = violations.map(&:to_s).join("; ")
        db_mutex.synchronize do
          @runs.append_log(
            run_id: run.id, step_id: step.id, stream: "system",
            content: redactor.redact("[contract:#{contract.name}] #{message}")
          )
        end

        case contract.on_violation
        when "warn"
          # Keep success status; just log. Output still flows to context.
          result
        when "retry"
          Runner::ExecutionResult.new(
            exit_code: result.exit_code,
            stdout: result.stdout, stderr: result.stderr,
            output_json: nil, # don't propagate violating output
            artifacts: result.artifacts,
            error_type: "contract_violation",
            error_message: redactor.redact("contract '#{contract.name}': #{message}"),
            duration_ms: result.duration_ms,
            started_at: result.started_at, finished_at: result.finished_at
          )
        else # "fail"
          Runner::ExecutionResult.new(
            exit_code: result.exit_code,
            stdout: result.stdout, stderr: result.stderr,
            output_json: nil,
            artifacts: result.artifacts,
            error_type: "contract_violation",
            error_message: redactor.redact("contract '#{contract.name}': #{message}"),
            duration_ms: result.duration_ms,
            started_at: result.started_at, finished_at: result.finished_at
          )
        end
      end

      def build_input_payload(run, block, context)
        {
          "run_id" => run.uid,
          "process" => run.process_name,
          "block" => block.name,
          "context" => context.to_h
        }
      end

      # Apply Util::Templater to every value in `fields`, leaving non-string
      # values untouched. Used to substitute {{ctx.path}} in per-call args
      # right before handing them to the caller.
      def templated_fields(fields, context)
        return fields if fields.empty?

        fields.each_with_object({}) do |(k, v), h|
          h[k] = case v
                 when String then Prouterd::Util::Templater.render(v, context)
                 when Hash   then v.transform_values { |sub| sub.is_a?(String) ? Prouterd::Util::Templater.render(sub, context) : sub }
                 else             v
                 end
        end
      end

      # Resolved-secret map keyed by secret name, exposed to templating as
      # the `secret.*` namespace. Operators can write
      # `dsn "{{secret.PG_DSN}}"` on an interface and the orchestrator
      # substitutes the resolved value at call time. Unresolved or
      # missing secrets render as the empty string (Templater convention).
      # Memoized per run via @secret_overlay_cache.
      def secret_overlay(document)
        @secret_overlay_cache ||= document.secrets.each_with_object({}) do |secret, h|
          h[secret.name] = @secret_resolver.resolve(secret).to_s
        end
      end

      def build_env(run, process, block, iface, document)
        env = {
          "PROUTER_RUN_ID" => run.uid,
          "PROUTER_PROCESS_NAME" => process.name,
          "PROUTER_BLOCK_NAME" => block.name,
          "PROUTER_ATTEMPT" => "1",
          "PROUTER_INPUT_PATH" => "/prouter/input.json",
          "PROUTER_OUTPUT_PATH" => "/prouter/output.json",
          "PROUTER_ARTIFACTS_DIR" => "/prouter/artifacts"
        }
        # Block-declared secrets — surfaced as PROUTER env vars to docker /
        # shell containers.
        block.secret_names.each do |secret_name|
          secret = document.secrets.find { |s| s.name == secret_name }
          unless secret
            raise TriggerError, "block '#{block.name}' references unknown secret '#{secret_name}'"
          end
          value = @secret_resolver.resolve(secret)
          # Resolved value may be nil if the host env var is unset; we still
          # forward an empty string so the container side can detect absence
          # without crashing on missing-key.
          env[secret_name] = value.to_s
        end
        # Interface-declared auth secret — outbound callers (HttpCaller,
        # LlmCaller) read the resolved token from env[secret_name] when
        # processing iface.type_fields["auth"].
        iface_auth = iface && iface.type_fields["auth"]
        if iface_auth
          secret = document.secrets.find { |s| s.name == iface_auth.secret_name }
          if secret
            env[iface_auth.secret_name] ||= @secret_resolver.resolve(secret).to_s
          end
        end
        env
      end

      def persist_logs(run, step, result, redactor)
        emitted = []
        @db.transaction do
          if result.stdout && !result.stdout.empty?
            content = redactor.redact(result.stdout)
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: content)
            emitted << ["stdout", content]
          end
          if result.stderr && !result.stderr.empty?
            content = redactor.redact(result.stderr)
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "stderr", content: content)
            emitted << ["stderr", content]
          end
          if result.error_message
            content = redactor.redact("[#{result.error_type}] #{result.error_message}")
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "system", content: content)
            emitted << ["system", content]
          end
        end

        ts = Time.now.utc.iso8601(3)
        emitted.each do |stream, content|
          @events.publish(:log_appended,
                          run_id:     run.id,
                          run_uid:    run.uid,
                          step_id:    step.id,
                          stream:     stream,
                          content:    content,
                          created_at: ts)
        end
      end

      def persist_artifacts(run, step, block, result)
        return if result.artifacts.nil? || result.artifacts.empty?

        archived = @artifact_store.archive(run.uid, block.name, result.artifacts)
        archived.each do |a|
          @runs.add_artifact(
            run_id: run.id,
            step_id: step.id,
            block_name: block.name,
            name: a.name,
            path: a.host_path,
            content_type: a.content_type,
            size_bytes: a.size_bytes,
            checksum: a.checksum
          )
        end
      end

      def update_context_with_output(block, context, result)
        return unless result.success? && result.output_json

        # Auto-key by block name. Downstream blocks reference via templating:
        # `{{<block_name>.field}}`.
        context.set(block.name, result.output_json)
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
        finalized
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
