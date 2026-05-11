# frozen_string_literal: true

require "set"

module Prouterd
  module Runtime
    # Retry / reflection-loop subsystem extracted from Orchestrator.
    #
    # Owns:
    #   * The per-block retry loop (`run_with_retries`) — drives both
    #     classic failure-retry AND reflection loops where a successful
    #     attempt is re-fired because output didn't satisfy a verifier.
    #   * `retry when` predicate evaluation against attempt result +
    #     run context.
    #   * `retry stop-on` kill switch evaluated against fresh run state
    #     after each attempt.
    #   * `retry feedback` value resolution (output.X / bare key / cross-
    #     block path) used to build `{{previous.*}}` for the next attempt.
    #   * Cross-block sweep — re-trigger an upstream block when its
    #     `retry when` predicate becomes true against the run context
    #     AFTER a downstream block writes.
    #   * OverlayContext — templating overlay that surfaces `iteration`,
    #     `previous.*`, and `secret.*` without polluting the shared run
    #     Context.
    #
    # The single instance-level dependency is the `runs` repository
    # (used for system-log lines and a fresh-state lookup in
    # `stop-on`). Everything else is passed in per-call. Single-attempt
    # execution is INVERTED: the caller passes a block that runs one
    # attempt and returns an ExecutionResult — RetryEngine drives the
    # loop, the caller owns the work.
    class RetryEngine
      # `output.X`, bare `X` (lacking a dot) — current-block paths.
      # Anything with `<head>.<rest>` where head is not `output` /
      # `error_type` / `error_message` / `exit_code` is a foreign
      # reference — interesting for the cross-block sweep.
      INNER_PREDICATE_HEADS = %w[output error_type error_message exit_code].freeze

      def initialize(runs:)
        @runs = runs
      end

      # Run one block's retry loop. The caller yields each attempt:
      #   yield(attempt_number, template_overlay) → ExecutionResult
      # The overlay carries `iteration` and `previous.*` (when available)
      # for use by `{{...}}` templating inside call-field values.
      def run_with_retries(run, process, block, context, document, db_mutex, ctx_mutex,
                           outer_overlay: nil)
        policy = lookup_policy(document, block.retry_policy_name)
        attempt = 1
        result = nil
        # When this execution was triggered by a cross-block retry
        # sweep, the sweep stashed the previous-summary (with cross-
        # block feedback already resolved) onto the block. Surface it
        # as `previous.*` for the very first attempt so the regenerator
        # template can read `{{previous.feedback}}` even though this
        # is "attempt 1" from the inner loop's perspective.
        previous_summary = outer_overlay

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

          result = yield(attempt, overlay)

          break if stop_triggered?(policy, run, block, db_mutex)
          break unless should_fire?(policy, result, run, block, db_mutex, context)
          break unless RetryCalculator.more_attempts?(policy, attempt)

          previous_summary = build_previous_summary(result, attempt, policy, context, ctx_mutex)
          attempt += 1
        end

        # The retry loop drives BOTH classic failure-retry and reflection
        # loops where a successful attempt is re-fired because output
        # didn't satisfy the verifier. If we exit the loop on a "logical
        # failure" success (predicate matched, attempts exhausted), the
        # block must surface this as a terminal failure — not silently
        # return success.
        ctx_snapshot = ctx_mutex.synchronize { Context.new(context.to_h) }
        if result&.success? && policy && match_against_result?(policy, result, run_context: ctx_snapshot)
          result = Runner::ExecutionResult.new(
            exit_code:     result.exit_code,
            stdout:        result.stdout, stderr: result.stderr,
            output_json:   result.output_json,
            artifacts:     result.artifacts,
            error_type:    "retry_when_unsatisfied",
            error_message: "retry-when matched on output but max attempts reached",
            duration_ms:   result.duration_ms,
            started_at:    result.started_at, finished_at: result.finished_at
          )
        end

        result
      end

      # Decide whether to retry after this attempt. The unified rule:
      #
      #   - With no `retry when` conditions on the policy: retry when the
      #     result is a failure (legacy behaviour).
      #   - With `retry when` conditions: retry iff at least one matches.
      #     Predicates can reference `output.<...>` so a successful result
      #     whose output flags a verifier-fail still triggers a retry.
      def should_fire?(policy, result, run, block, db_mutex, run_context = nil)
        return false if policy.nil?

        if policy.retry_when_matches.empty?
          return !result.success?
        end

        passes = match_against_result?(policy, result, run_context: run_context)
        unless passes || result.success?
          # Failure that didn't match any predicate — terminal.
          db_mutex.synchronize do
            @runs.append_log(
              run_id: run.id, stream: "system",
              content: "block '#{block.name}' failed with error_type=#{result.error_type.inspect} — no retry-when condition matched, treating as terminal"
            )
          end
        end
        passes
      end

      # `retry stop-on <path> <op> <val>` — kill switch evaluated
      # against current run state after each attempt. Today the only
      # exposed namespace is `run.{cost_usd, tokens_in, tokens_out}`
      # (refreshed from the DB so cost_usd reflects this attempt's
      # accumulator bump).
      def stop_triggered?(policy, run, block, db_mutex)
        return false if policy.nil? || policy.retry_stop_matches.empty?

        refreshed = db_mutex.synchronize { @runs.get_run(run.id) }
        return false unless refreshed

        synthetic = {
          "run" => {
            "cost_usd"   => refreshed.cost_usd.to_f,
            "tokens_in"  => refreshed.tokens_in.to_i,
            "tokens_out" => refreshed.tokens_out.to_i
          }
        }
        ctx = OverlayContext.new({}, synthetic)
        triggered = policy.retry_stop_matches.any? { |m| MatchEvaluator.evaluate(m, ctx) }
        if triggered
          db_mutex.synchronize do
            @runs.append_log(
              run_id: run.id, stream: "system",
              content: "block '#{block.name}' retry stop-on triggered (run cost_usd=#{refreshed.cost_usd}); aborting retry loop"
            )
          end
        end
        triggered
      end

      # Walks every executed block and asks: "does my policy's
      # retry-when now match against the run-context as it stands
      # after this level?" If yes — and the block has an outer-retry
      # budget remaining — schedule the block (and everything
      # downstream-reachable from it) for re-execution. Returns the
      # list of block names to re-run.
      #
      # Predicate paths starting with `output.` reference the current
      # attempt's own output and never trigger from this sweep —
      # those fire from the inner per-block retry loop. Only foreign
      # paths (`<other_block>.<field>`) are interesting here.
      def sweep_cross_block(process, document, block_results, executed,
                            context, ctx_mutex, outer_attempts, outer_overlays)
        retriggered = []
        executed.to_a.each do |bn|
          block = process.block(bn)
          next unless block

          policy = lookup_policy(document, block.retry_policy_name)
          next if policy.nil? || policy.retry_when_matches.empty?

          # Skip predicates that only reference current-block paths —
          # those are the inner-retry-loop's job.
          next unless policy.retry_when_matches.any? { |m| foreign_predicate_path?(m.path) }

          # Budget already spent? Don't re-trigger. retry_attempts
          # is the total cap including the initial run, so we allow
          # (retry_attempts - 1) cross-block re-triggers.
          next if outer_attempts[bn] + 1 >= (policy.retry_attempts || 1)

          result = block_results[bn]
          next unless result

          ctx_snapshot = ctx_mutex.synchronize { Context.new(context.to_h) }
          next unless match_against_result?(policy, result, run_context: ctx_snapshot)

          # Match. Build the cross-block previous-summary BEFORE
          # clearing context, so feedback values come from the live
          # downstream output. Then clear the block + its downstream-
          # reachable peers so the next pass re-walks them.
          outer_attempts[bn] += 1
          outer_overlays[bn] = build_previous_summary(result, outer_attempts[bn] + 1, policy, ctx_snapshot, nil)
          dirty = downstream_reachable(process, bn)
          # Clear context for the upstream block + every block
          # downstream-reachable from it, so the re-walk sees them
          # as "hasn't run yet". Writing nil is enough — Context.get
          # surfaces missing keys as nil consistently, so templating
          # downstream of the soon-to-rerun blocks sees the same
          # "not yet" shape it would on a fresh run.
          ctx_mutex.synchronize do
            ([bn] + dirty.to_a).each { |n| context.set(n, nil) }
          end
          dirty.each { |n| executed.delete(n); block_results.delete(n); outer_overlays.delete(n) }
          executed.delete(bn)
          retriggered << bn
        end
        retriggered
      end

      # Evaluate the policy's retry-when matches against the unified
      # context: failure metadata + the attempt's output_json
      # under the `output.*` namespace + the entire run context (so a
      # predicate can reference any other block's output by name —
      # `retry when verify.status eq "fail"`). The synthetic overlay
      # WINS over context lookups: `output` is always the current
      # attempt; `error_type` etc. are always the current attempt's
      # error metadata.
      def match_against_result?(policy, result, run_context: nil)
        return false if policy.retry_when_matches.empty?

        synthetic = {
          "error_type"    => result.error_type,
          "error_message" => result.error_message,
          "exit_code"     => result.exit_code,
          "output"        => result.output_json || {}
        }
        ctx = OverlayContext.new(run_context || Context.new({}), synthetic)
        policy.retry_when_matches.any? { |m| MatchEvaluator.evaluate(m, ctx) }
      end

      def build_previous_summary(result, attempt, policy, context = nil, ctx_mutex = nil)
        summary = {
          "attempt"       => attempt,
          "error_type"    => result.error_type,
          "error_message" => result.error_message,
          "exit_code"     => result.exit_code,
          "stdout"        => result.stdout.to_s,
          "stderr"        => result.stderr.to_s
        }
        if policy
          policy.retry_feedbacks.each do |fb|
            summary[fb.into] = resolve_feedback_value(result, fb.from, context: context, ctx_mutex: ctx_mutex)
          end
        end
        summary
      end

      # `retry feedback <path> into <local>` — pull a value out of the
      # current attempt's output_json OR any other block's output via
      # dotted path. Resolution rules:
      #
      #   output.X       — current attempt's output_json[X] (back-compat)
      #   X              — bare key, current attempt's output_json[X]
      #                    (back-compat — unless X collides with a block name)
      #   <block>.X      — looked up in the run context, so e.g.
      #                    `feedback verify.issues` reads the audit
      #                    block's output even when the policy attaches
      #                    to the upstream generator block
      #
      # Missing paths surface as nil; the templater renders nil as the
      # empty string, so `{{previous.feedback}}` is always safe.
      def resolve_feedback_value(result, path, context: nil, ctx_mutex: nil)
        if path.start_with?("output.")
          return nil unless result.output_json
          return self.class.resolve_dotted_path(result.output_json, path.sub(/\Aoutput\./, ""))
        end

        # Attempt cross-block lookup if we have a context. The path's
        # head is treated as a block name; the rest as a dotted path
        # within that block's output. Falls back to the current
        # attempt's output_json when context lookup yields nil — keeps
        # bare-path back-compat (`retry feedback issues into feedback`).
        if context
          head = path.to_s.split(".", 2).first
          value = ctx_mutex ? ctx_mutex.synchronize { context.get(path) } : context.get(path)
          return value unless value.nil? && head && head != "output"
        end

        return nil unless result.output_json
        self.class.resolve_dotted_path(result.output_json, path)
      end

      def lookup_policy(document, policy_name)
        return nil if policy_name.nil?

        document.policies.find { |p| p.name == policy_name }
      end

      # Generic dotted-path walker over a JSON-shaped Hash/Array tree.
      # Returns nil if any intermediate hop is non-traversable.
      # Exposed as a class method because fan-out templating uses it
      # too (it's a pure utility, not retry-specific).
      def self.resolve_dotted_path(root, path)
        return nil unless root

        path.to_s.split(".").reduce(root) do |acc, key|
          if acc.is_a?(Hash)
            acc[key] || acc[key.to_sym]
          elsif acc.is_a?(Array) && key =~ /\A\d+\z/
            acc[key.to_i]
          else
            break nil
          end
        end
      end

      private

      # `output.X`, bare `X` (lacking a dot) — current-block paths.
      # Anything with `<head>.<rest>` where head is not in
      # INNER_PREDICATE_HEADS is a foreign reference — interesting for
      # the cross-block sweep.
      def foreign_predicate_path?(path)
        head, rest = path.to_s.split(".", 2)
        return false if rest.nil? || rest.empty?
        return false if INNER_PREDICATE_HEADS.include?(head)

        true
      end

      def downstream_reachable(process, start_block)
        seen = Set.new
        frontier = [start_block]
        until frontier.empty?
          n = frontier.shift
          process.routes.each do |r|
            next unless r.from_block == n
            next if seen.include?(r.to_block)

            seen << r.to_block
            frontier << r.to_block
          end
        end
        seen
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
    end
  end
end
