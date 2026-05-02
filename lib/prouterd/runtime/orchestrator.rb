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

      def initialize(db:, runner:, artifact_store: nil, secret_resolver: nil, logger: nil,
                     max_parallelism: 8)
        @db = db
        @runner = runner
        @runs = Storage::Repositories::Runs.new(db)
        @artifact_store = artifact_store || ArtifactStore.new
        @secret_resolver = secret_resolver || EnvSecretResolver.new
        @logger = logger
        @max_parallelism = max_parallelism
      end

      # Trigger a process. Returns the Run record after execution completes.
      #
      # `document` is the AST::Document to interpret the trigger against
      # (typically session.running_config or the running commit).
      # `commit_id` is the optional ID of the config commit pinning the run.
      def trigger(document, process_name, input_event:, interface_name: nil, commit_id: nil)
        process = document.processes.find { |p| p.name == process_name }
        raise TriggerError, "no such process '#{process_name}'" unless process

        run = @runs.create_run(
          process_name: process_name,
          process_config_commit_id: commit_id,
          interface_name: interface_name,
          input_event: input_event
        )

        execute(run, process, document)
      end

      private

      def execute(run, process, document)
        @runs.update_run(run.id, status: "running", started_at: Time.now.utc.iso8601(3))

        context = Context.new("event" => deep_stringify(run.input_event_json ? JSON.parse(run.input_event_json) : {}))

        # Per-run mutexes: DB writes serialized, context reads/writes guarded.
        db_mutex = Mutex.new
        ctx_mutex = Mutex.new

        ready = entry_blocks(process)
        if ready.empty?
          finalize_run(run, status: "failed", error: "process '#{process.name}' has no entry blocks")
          return @runs.get_run(run.id)
        end

        executed = Set.new
        failure_reason = nil

        until ready.empty?
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

          results = run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex)
          level.each { |b| executed << b.name }

          # Persist accumulated context once after the level drains.
          db_mutex.synchronize { update_run_context(run, context) }

          first_failure = results.find { |_, r| !r.success? }
          if first_failure
            block_name, result = first_failure
            failure_reason = "block '#{block_name}' #{result.error_type || 'failed'}: " \
                             "#{result.error_message || "exit #{result.exit_code}"}"
            break
          end

          # Build the next level: every successfully completed block contributes
          # the downstream blocks whose match conditions pass.
          next_ready = []
          level.each do |block|
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
      # return [[block_name, ExecutionResult], ...] in arbitrary order.
      def run_level_in_parallel(run, process, document, level, context, db_mutex, ctx_mutex)
        return [] if level.empty?

        if level.length == 1 || @max_parallelism <= 1
          return level.map do |block|
            [block.name, execute_block_threadsafe(run, process, block, context, document, db_mutex, ctx_mutex)]
          end
        end

        threads = level.map do |block|
          Thread.new do
            [block.name, execute_block_threadsafe(run, process, block, context, document, db_mutex, ctx_mutex)]
          end
        end
        threads.map(&:value)
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

      # Thread-safe variant. DB writes go through db_mutex; context read for
      # input + write for output go through ctx_mutex.
      def execute_block_threadsafe(run, process, block, context, document, db_mutex, ctx_mutex)
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
            attempt: 1,
            image: block.image
          )
          @runs.update_step(
            step.id,
            status: "running",
            started_at: Time.now.utc.iso8601(3),
            input_json: JSON.dump(input_payload)
          )
        end

        env = build_env(run, process, block, document)
        request = Runner::RunRequest.new(
          run_uid: run.uid,
          process_name: process.name,
          block_name: block.name,
          attempt: 1,
          image: block.image,
          command: block.command,
          env: env,
          input_json: input_payload,
          timeout_ms: block.timeout_ms,
          network: block.network || "on"
        )

        # Runner call happens OUTSIDE both mutexes — that's the whole point.
        result = @runner.run(request)

        db_mutex.synchronize do
          persist_logs(run, step, result)
          persist_artifacts(run, step, block, result)
          @runs.update_step(
            step.id,
            status: result.to_step_status,
            finished_at: Time.now.utc.iso8601(3),
            duration_ms: result.duration_ms,
            exit_code: result.exit_code,
            error_type: result.error_type,
            error_message: result.error_message,
            output_json: result.output_json ? JSON.dump(result.output_json) : nil
          )
        end

        ctx_mutex.synchronize do
          update_context_with_output(block, context, result)
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
        env
      end

      def persist_logs(run, step, result)
        @db.transaction do
          @runs.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: result.stdout) if result.stdout && !result.stdout.empty?
          @runs.append_log(run_id: run.id, step_id: step.id, stream: "stderr", content: result.stderr) if result.stderr && !result.stderr.empty?
          if result.error_message
            @runs.append_log(run_id: run.id, step_id: step.id, stream: "system", content: "[#{result.error_type}] #{result.error_message}")
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
        @runs.update_run(
          run.id,
          status: status,
          finished_at: Time.now.utc.iso8601(3),
          error_summary: error
        )
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
