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

      # `runner` is either a single runner (legacy, treated as docker) or a
      # Hash<String, Runner> mapping execution_type → runner instance.
      # Phase 12 introduced the `block ... type docker|shell` DSL; the
      # orchestrator dispatches based on block.execution_type.
      def initialize(db:, runner:, artifact_store: nil, secret_resolver: nil, logger: nil,
                     max_parallelism: 8, in_flight: nil, metrics: nil)
        @db = db
        @runners = normalize_runners(runner)
        @runs = Storage::Repositories::Runs.new(db)
        @artifact_store = artifact_store || ArtifactStore.new
        @secret_resolver = secret_resolver || EnvSecretResolver.new
        @logger = logger
        @max_parallelism = max_parallelism
        @in_flight = in_flight
        @metrics = metrics
      end

      def normalize_runners(runner)
        return runner.transform_keys(&:to_s) if runner.is_a?(Hash)

        # Legacy: single runner means "use this for everything". Treat as
        # docker for backward compat — most existing tests use StubRunner
        # for either kind, and StubRunner doesn't care about execution_type.
        { "docker" => runner, "shell" => runner }
      end

      def runner_for(block)
        kind = block.execution_type || "docker"
        @runners[kind] || @runners["docker"] || raise(TriggerError, "no runner registered for type '#{kind}'")
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

        @runs.create_run(
          process_name: process_name,
          process_config_commit_id: commit_id,
          interface_name: interface_name,
          input_event: input_event,
          replay_of_run_id: replay_of_run_id
        )
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
        @runs.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))

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

          result = execute_single_attempt(run, process, block, attempt, context, document, db_mutex, ctx_mutex, redactor)
          break if result.success?
          break unless RetryCalculator.more_attempts?(policy, attempt)

          attempt += 1
        end

        result
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
      def execute_single_attempt(run, process, block, attempt, context, document, db_mutex, ctx_mutex, redactor)
        input_payload = nil
        ctx_mutex.synchronize do
          input_value = block.input ? context.get(block.input) : nil
          input_payload = build_input_payload(run, block, input_value, context)
        end

        step = nil
        db_mutex.synchronize do
          step = @runs.create_step(
            run_id: run.id,
            block_name: block.name,
            attempt: attempt,
            image: block.image
          )
          @runs.update_step(
            step.id,
            status: attempt == 1 ? "running" : "retrying",
            started_at: Time.now.utc.iso8601(3),
            input_json: JSON.dump(input_payload)
          )
          @runs.update_step(step.id, status: "running") if attempt > 1
        end

        env = build_env(run, process, block, document)
        # Shell type: prefer block.shell_exec as the command. Docker type:
        # block.command (image's CMD override). The runner consults
        # execution_type for which fields apply.
        command = block.shell? ? block.shell_exec : block.command
        request = Runner::RunRequest.new(
          run_uid: run.uid,
          process_name: process.name,
          block_name: block.name,
          execution_type: block.execution_type || "docker",
          attempt: attempt,
          image: block.image,
          command: command,
          env: env,
          input_json: input_payload,
          timeout_ms: block.timeout_ms,
          network: block.network || "on",
          cwd: block.shell_cwd,
          shell_path: block.shell_path,
          pull: block.pull,
          user: block.user,
          memory: block.memory,
          cpu: block.cpu
        )

        result = runner_for(block).run(request)

        db_mutex.synchronize do
          persist_logs(run, step, result, redactor)
          persist_artifacts(run, step, block, result)
          @runs.update_step(
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

        if result.success?
          ctx_mutex.synchronize { update_context_with_output(block, context, result) }
        end

        result
      end

      def build_input_payload(run, block, input_value, context)
        {
          "run_id" => run.uid,
          "process" => run.process_name,
          "block" => block.name,
          "input" => input_value,
          "context" => context.to_h
        }
      end

      def build_env(run, process, block, document)
        env = {
          "PROUTER_RUN_ID" => run.uid,
          "PROUTER_PROCESS_NAME" => process.name,
          "PROUTER_BLOCK_NAME" => block.name,
          "PROUTER_ATTEMPT" => "1",
          "PROUTER_INPUT_PATH" => "/prouter/input.json",
          "PROUTER_OUTPUT_PATH" => "/prouter/output.json",
          "PROUTER_ARTIFACTS_DIR" => "/prouter/artifacts"
        }
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
        # Shell blocks may declare custom env via `env KEY VALUE`. Merge
        # AFTER PROUTER_* so the user can intentionally override them if
        # they really want to. ShellRunner re-overrides the file-path env
        # vars to point at its actual work_dir.
        if block.shell? && block.shell_env
          env.merge!(block.shell_env)
        end
        env
      end

      def persist_logs(run, step, result, redactor)
        @db.transaction do
          if result.stdout && !result.stdout.empty?
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: redactor.redact(result.stdout))
          end
          if result.stderr && !result.stderr.empty?
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "stderr", content: redactor.redact(result.stderr))
          end
          if result.error_message
            @runs.append_log(
              run_id: run.id, step_id: step.id, stream: "system",
              content: redactor.redact("[#{result.error_type}] #{result.error_message}")
            )
          end
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
        return unless result.success? && result.output_json && block.output

        context.set(block.output, result.output_json)
      end

      def update_run_context(run, context)
        @runs.update_run(run.id, context_json: JSON.dump(context.to_h))
      end

      def finalize_run(run, status:, error: nil)
        @metrics&.increment(:runs_total, process: run.process_name, status: status)
        @runs.update_run(
          run.id,
          status: status,
          finished_at: Time.now.utc.iso8601(3),
          error_summary: error
        )
      end

      def finalize_canceled(run)
        # The cancel command already stamped run.status; we keep that and
        # just return the row. Don't overwrite finished_at — the cancel
        # command set it the moment the operator hit cancel.
        @runs.get_run(run.id)
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

    # Resolves a secret reference into a runtime value. Spec §8.3 only
    # supports `source env`; other backends (vault, aws) get added as
    # additional resolvers later.
    class EnvSecretResolver
      def resolve(secret)
        case secret.source_type
        when "env" then ENV[secret.source_value]
        else raise TriggerError, "unsupported secret source '#{secret.source_type}'"
        end
      end
    end
  end
end
