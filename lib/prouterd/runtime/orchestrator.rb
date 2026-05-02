require "json"
require "time"
require "set"

module Prouterd
  module Runtime
    class TriggerError < StandardError; end

    # Drives a process from trigger to completion.
    #
    # Phase 4 scope:
    #   * Manual trigger (an event Hash) creates a Run record.
    #   * Walk the block DAG starting at entry blocks (no incoming routes).
    #   * For each block: build input from context, hand it to a Runner,
    #     persist Step + logs + artifacts, fold output back into context.
    #   * On block failure: mark Run failed and stop (no retries — Phase 6).
    #   * Sequential single-thread execution (parallel branching — Phase 5).
    #   * No match conditions on routes (Phase 5); every outgoing route is
    #     followed unconditionally.
    #
    # The orchestrator depends only on small abstractions (Runner, ArtifactStore,
    # Repositories::Runs) so unit tests stub the Runner cleanly.
    class Orchestrator
      attr_reader :runs

      def initialize(db:, runner:, artifact_store: nil, secret_resolver: nil, logger: nil)
        @db = db
        @runner = runner
        @runs = Storage::Repositories::Runs.new(db)
        @artifact_store = artifact_store || ArtifactStore.new
        @secret_resolver = secret_resolver || EnvSecretResolver.new
        @logger = logger
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

        # Sequential single-thread executor. The queue is a list of block
        # names ready to run; it grows as outgoing routes are followed.
        queue = entry_blocks(process)
        if queue.empty?
          finalize_run(run, status: "failed", error: "process '#{process.name}' has no entry blocks")
          return @runs.get_run(run.id)
        end
        executed = Set.new
        failure_reason = nil

        until queue.empty?
          block_name = queue.shift
          next if executed.include?(block_name)

          block = process.block(block_name)
          unless block
            failure_reason = "block '#{block_name}' is not defined"
            break
          end
          if block.shutdown
            update_run_context(run, context)
            executed << block_name
            log_system(run, "block '#{block_name}' is shutdown; skipped")
            queue.concat(downstream_blocks(process, block_name))
            next
          end

          step_outcome = execute_block(run, process, block, context, document)
          executed << block_name
          update_run_context(run, context)

          unless step_outcome.success?
            failure_reason = "block '#{block_name}' #{step_outcome.error_type || 'failed'}: #{step_outcome.error_message || 'exit ' + step_outcome.exit_code.to_s}"
            break
          end

          # Phase 4: enqueue every outgoing route unconditionally.
          downstream_blocks(process, block_name).each do |next_block|
            queue << next_block unless executed.include?(next_block) || queue.include?(next_block)
          end
        end

        if failure_reason
          finalize_run(run, status: "failed", error: failure_reason)
        else
          finalize_run(run, status: "success")
        end
        @runs.get_run(run.id)
      end

      def entry_blocks(process)
        with_incoming = process.routes.map(&:to_block).to_set
        process.blocks.reject { |b| with_incoming.include?(b.name) }.map(&:name)
      end

      def downstream_blocks(process, from_block)
        process.routes.select { |r| r.from_block == from_block }.map(&:to_block)
      end

      def execute_block(run, process, block, context, document)
        step = @runs.create_step(
          run_id: run.id,
          block_name: block.name,
          attempt: 1,
          image: block.image
        )
        input_value = block.input ? context.get(block.input) : nil
        input_payload = build_input_payload(run, block, input_value, context)

        @runs.update_step(
          step.id,
          status: "running",
          started_at: Time.now.utc.iso8601(3),
          input_json: JSON.dump(input_payload)
        )

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

        result = @runner.run(request)

        persist_logs(run, step, result)
        persist_artifacts(run, step, block, result)
        update_context_with_output(block, context, result)

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
