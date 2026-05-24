# frozen_string_literal: true

require "json"
require "time"
require "set"

module Prouterd
  module Runtime
    # Single-block execution path, extracted from Orchestrator.
    #
    # Drives one block-attempt end-to-end:
    #
    #   1. Special dispatch: barrier blocks (synthetic from `parallel`)
    #      and `agentic on` blocks short-circuit to their dedicated paths.
    #   2. Resolve `interface` reference, validate it exists.
    #   3. Template both interface body and per-call block fields,
    #      with `secret.*` / `iteration` / `previous` / `vars` overlays.
    #   4. Persist a step row (running / retrying), publish events.
    #   5. Stage `input X from Y.Z` artifact inputs from archive.
    #   6. Build the run-time env (PROUTER_*, secret-name env vars,
    #      interface-auth env var).
    #   7. Dispatch to the @runner with a RunRequest.
    #   8. Enforce `produces` declarations + output `contract`.
    #   9. Redact result.output_json with the per-run redactor.
    #  10. Persist logs / artifacts / final step row, accumulate per-run
    #      LLM cost.
    #  11. Apply `max-cost-usd` post-attempt guard.
    #  12. On success: seed the shared run Context with the block's
    #      output; fan-out child runs if the block declares fan-out.
    #
    # Owns AgenticRunner and FanOut sub-collaborators (each takes the
    # BlockExecutor as `host:`, since both reach back into BlockExecutor
    # for shared helpers: AgenticRunner uses secret_overlay /
    # templated_fields / build_env / accumulate_run_usage /
    # update_context_with_output; FanOut uses log_system_safe).
    class BlockExecutor
      include SystemLog

      def initialize(db:, runs:, runner:, artifact_store:,
                     secret_resolver:, events:, logger:, mcp_pool:,
                     retry_engine:)
        @db = db
        @runs = runs
        @runner = runner
        @artifact_store = artifact_store
        @secret_resolver = secret_resolver
        @events = events
        @logger = logger
        @retry_engine = retry_engine
        @agentic_runner = AgenticRunner.new(
          runs: @runs, runner: @runner, mcp_pool: mcp_pool, host: self
        )
        @fan_out = FanOut.new(db: @db, runs: @runs, host: self)
      end

      def execute_single_attempt(run, process, block, attempt, context, document, db_mutex, ctx_mutex, redactor, template_overlay: nil)
        # Synthesized barrier blocks (from `parallel <name>` expansion)
        # are no-op aggregators: they don't dispatch to any runner.
        # Compose the group's output_json from member blocks' outputs
        # already on the context, write a step row, and return success.
        return execute_barrier_block(run, block, context, ctx_mutex, db_mutex) if block.barrier?

        # Agentic multi-turn tool-use loop. Drives the provider's tool
        # API in a loop, dispatching each tool_use through the same
        # CallRunner that ordinary blocks use. Currently Anthropic only
        # — OpenAI's function-calling shape needs its own driver.
        return @agentic_runner.execute(run, process, block, context, document, db_mutex, ctx_mutex, redactor, attempt) if block.agentic

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
        scope = RetryEngine::OverlayContext.new(context, overlay)
        input_payload = nil
        templated_iface_fields = nil
        templated_call_fields = nil
        ctx_mutex.synchronize do
          input_payload = build_input_payload(run, block, context)
          # Resolve `vars` first against the base scope so call-fields can
          # reference them by their local names instead of the underlying
          # paths (e.g. `{{evidence}}` rather than `{{event.body.evidence}}`).
          unless block.vars.empty?
            resolved_vars = block.vars.transform_values do |tmpl|
              Prouterd::Util::Templater.render(tmpl, scope)
            end
            scope = RetryEngine::OverlayContext.new(context, overlay.merge(resolved_vars))
          end
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

        # Per-step append-as-you-go log writer for runners that stream
        # (subprocess LLM with `stream on` is the only consumer today).
        # Each call lands an immediate row in run_logs so `prouter logs
        # <run_uid>` can live-tail a long agent run. Runners that finish
        # synchronously simply leave it untouched and let persist_logs
        # bulk-write at the end.
        log_sink = build_log_sink(run, step, db_mutex, redactor)

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
          staged_inputs: staged_inputs,
          log_sink: log_sink
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

        # Phase 35c: scrub secret values out of output_json BEFORE we
        # persist the step row OR seed the shared run Context. Without
        # this, a block that echoed `{{secret.X}}` back into its output
        # would leak the resolved value to every downstream block via
        # context-templating + /prouter/input.json, AND to the persisted
        # run_steps.output_json column.
        scrubbed_output = result.output_json ? redactor.redact_json(result.output_json) : nil

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
            output_json: scrubbed_output ? JSON.dump(scrubbed_output) : nil
          )
          accumulate_run_usage(run, scrubbed_output, iface, document)
        end
        @events.publish(:step_updated, step: finished_step, run_id: run.id, run_uid: run.uid) if finished_step

        # Post-attempt cost guardrail: if the block declares
        # max-cost-usd and accumulated run cost crossed it, reshape
        # the result into a terminal failure so retries don't keep
        # burning budget.
        if block.max_cost_usd
          refreshed = db_mutex.synchronize { @runs.get_run(run.id) }
          if refreshed && refreshed.cost_usd.to_f > block.max_cost_usd.to_f
            result = Runner::ExecutionResult.new(
              exit_code:     result.exit_code,
              stdout:        result.stdout, stderr: result.stderr,
              output_json:   result.output_json,
              artifacts:     result.artifacts,
              error_type:    "cost_cap_exceeded",
              error_message: "block exceeded max-cost-usd #{block.max_cost_usd} (run cost_usd=#{refreshed.cost_usd})",
              duration_ms:   result.duration_ms,
              started_at:    result.started_at, finished_at: result.finished_at
            )
          end
        end

        if result.success?
          ctx_mutex.synchronize { update_context_with_output(block, context, scrubbed_output) }
          @fan_out.fan_out_children(run, block, document, scrubbed_output, db_mutex) if block.fan_out?
        end

        result
      end

      # Host contract for AgenticRunner — exposed as public so the
      # collaborator can reach back without metaprogramming. Phase 4's
      # transitional state. After we extract MOAR stuff these can be
      # promoted to a proper interface module.

      def secret_overlay(document)
        @secret_overlay_cache ||= document.secrets.each_with_object({}) do |secret, h|
          h[secret.name] = @secret_resolver.resolve(secret).to_s
        end
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
          if value.nil? || value.to_s.empty?
            @logger.warn("secret resolved to empty value",
                         facility: "SECRET", mnemonic: "MISSING",
                         secret: secret_name, source: secret.source_type,
                         block: block.name, run_uid: run.uid)
          end
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
        # Generic resolution of `:secret_ref` fields on the interface
        # (e.g. `interface llm` and `interface mcp` both accept
        # `secret <NAME>`). Plugin-driven so a third-party iface gets
        # this for free.
        if iface
          plugin = Iface::Registry.lookup(iface.type)
          if plugin
            plugin.fields.each do |field|
              next unless field.kind == :secret_ref

              Array(iface.type_fields[field.storage_key]).each do |secret_name|
                secret = document.secrets.find { |s| s.name == secret_name }
                next unless secret

                env[secret_name] ||= @secret_resolver.resolve(secret).to_s
              end
            end
          end
        end
        env
      end

      # Accumulate per-run LLM token usage + USD cost when the
      # attempt's output_json carries the canonical `usage` envelope
      # (LlmCaller normalises both Anthropic and OpenAI providers to
      # {input_tokens, output_tokens}). Cost is computed against the
      # `prices <provider>` table for the iface's provider+model;
      # missing entries record 0 cost (token usage still bumped).
      # Caller must hold db_mutex.
      def accumulate_run_usage(run, output_json, iface = nil, document = nil)
        return unless output_json.is_a?(Hash)

        usage = output_json["usage"]
        return unless usage.is_a?(Hash)

        tokens_in  = (usage["input_tokens"]  || usage["prompt_tokens"]    || 0).to_i
        tokens_out = (usage["output_tokens"] || usage["completion_tokens"] || 0).to_i
        cost = price_for_call(iface, output_json["model"], document, tokens_in, tokens_out)
        @runs.add_run_usage(run.id, tokens_in: tokens_in, tokens_out: tokens_out, cost_usd: cost)
      end

      # Caller passes ALREADY-REDACTED output_json (Phase 35c). The shared
      # Context flows into every downstream block's call-fields via
      # templating and into /prouter/input.json — secrets must never get
      # there.
      def update_context_with_output(block, context, scrubbed_output_json)
        return unless scrubbed_output_json

        # Auto-key by block name. Downstream blocks reference via templating:
        # `{{<block_name>.field}}`.
        context.set(block.name, scrubbed_output_json)
      end

      private

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

      # Barrier execution path. Builds output_json keyed by member block
      # name where the value is each member's recorded context entry
      # (nil if the member was skipped or failed). Persists a synthetic
      # step row, seeds context[barrier.name] with the aggregated map,
      # and returns success — the orchestrator's normal route walk
      # then activates routes downstream of the parallel group.
      def execute_barrier_block(run, block, context, ctx_mutex, db_mutex)
        members = block.barrier_for || []
        aggregated = {}
        succeeded = []
        ctx_mutex.synchronize do
          members.each do |m|
            value = context.get(m)
            aggregated[m] = value
            succeeded << m unless value.nil?
          end
        end

        if block.barrier_join_strategy == "any"
          # OR-join: barrier output is the first-terminated member's
          # output. The scheduler fires this barrier as soon as a single
          # member's route passes, so by the time we land here, exactly
          # the early finishers have context entries; later members
          # never contribute. Output shape carries the winner's name
          # explicitly so downstream blocks can branch on it.
          winner = nil
          winner_output = nil
          ctx_mutex.synchronize do
            members.each do |m|
              v = context.get(m)
              next if v.nil?

              winner = m
              winner_output = v
              break
            end
          end
          output = { "winner" => winner, "output" => winner_output, "join_strategy" => "any" }
        elsif block.barrier_join_strategy == "merge-children"
          # Shallow-merge every member's output Hash so the barrier's
          # output is one flat object across all children. Lets a
          # parallel group satisfy a single contract whose shape is
          # the union of children's outputs (e.g. {jira, slack,
          # sentry}). Non-Hash member outputs are skipped — they
          # have no keys to merge. Later members win on key collision
          # (members ordered as declared).
          merged = {}
          members.each do |m|
            value = aggregated[m]
            merged.merge!(value) if value.is_a?(Hash)
          end
          output = merged
        else
          output = {
            "members"   => aggregated,
            "succeeded" => succeeded,
            "failed"    => members - succeeded,
            "join_strategy" => block.barrier_join_strategy
          }
        end
        now = Time.now.utc.iso8601(3)
        db_mutex.synchronize do
          step = @runs.create_step(run_id: run.id, block_name: block.name, attempt: 1, image: nil)
          @runs.update_step(
            step.id,
            status: "success",
            started_at: now,
            finished_at: now,
            duration_ms: 0,
            exit_code: 0,
            output_json: JSON.dump(output)
          )
        end
        ctx_mutex.synchronize { context.set(block.name, output) }

        Runner::ExecutionResult.new(
          exit_code: 0, stdout: "", stderr: "",
          output_json: output, artifacts: [],
          error_type: nil, error_message: nil,
          duration_ms: 0, started_at: now, finished_at: now
        )
      end

      # Look up `prices <provider>` for the iface's provider, find the
      # matching `model <name>` entry, and compute USD cost. Returns 0.0
      # when any piece is missing — token telemetry still records, the
      # operator sees missing cost in `runs.cost_usd` and adds the
      # entry.
      def price_for_call(iface, model, document, tokens_in, tokens_out)
        return 0.0 unless iface && document && model
        provider = iface.type_fields["provider"]
        return 0.0 unless provider

        table = document.prices.find { |p| p.provider == provider }
        return 0.0 unless table
        entry = table.entries.find { |e| e.model == model }
        return 0.0 unless entry

        ((tokens_in.to_f * entry.price_in) + (tokens_out.to_f * entry.price_out)) / 1_000_000.0
      end

      def build_input_payload(run, block, context)
        {
          "run_id" => run.uid,
          "process" => run.process_name,
          "block" => block.name,
          "context" => context.to_h
        }
      end

      # Wraps `@runs.append_log` + the events bus into a thread-safe
      # callable usable from worker threads inside the runner. Each
      # invocation persists one log line and publishes a `:log_appended`
      # event so live-tail consumers (WS, CLI follow) see it
      # immediately. Returns nil — the caller is fire-and-forget.
      def build_log_sink(run, step, db_mutex, redactor)
        run_id  = run.id
        run_uid = run.uid
        step_id = step.id
        proc do |content, stream = "stdout"|
          next if content.nil? || content.to_s.empty?

          redacted = redactor.redact(content.to_s)
          db_mutex.synchronize do
            @runs.append_log(run_id: run_id, step_id: step_id, stream: stream, content: redacted)
          end
          if @events
            @events.publish(:log_appended,
                            run_id:  run_id, run_uid: run_uid, step_id: step_id,
                            stream:  stream, content: redacted,
                            ts:      Time.now.utc.iso8601(3))
          end
          nil
        end
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
    end
  end
end
