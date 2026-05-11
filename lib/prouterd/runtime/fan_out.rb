# frozen_string_literal: true

require "time"

module Prouterd
  module Runtime
    # `fan-out from <path> into <process>` execution path, extracted
    # from Orchestrator.
    #
    # When a block's output is an array, the upstream block enqueues one
    # child run of the target process per element. Optional enrichment:
    #   * `map`         — project upstream item fields into the child event
    #   * `dedupe`      — skip items whose `prior-run` matches in window
    #   * `rate-limit`  — stagger child enqueue via jobs.available_at
    #
    # Lineage queryable via runs.parent_run_id.
    class FanOut
      def initialize(db:, runs:, host:)
        @db = db
        @runs = runs
        @host = host
        @jobs_repo = nil
      end

      # Walk the upstream block's redacted output_json and enqueue one
      # child run of <process> per element. No-op when fan-out points
      # at an absent process, when the path isn't an Array, or when
      # the Array is empty.
      def fan_out_children(run, block, document, output_json, db_mutex)
        target_process = document.processes.find { |p| p.name == block.fan_out_into }
        unless target_process
          @host.log_system_safe(run,
            "fan-out: target process '#{block.fan_out_into}' not declared in document — skipping",
            db_mutex)
          return
        end

        items = RetryEngine.resolve_dotted_path(output_json, block.fan_out_from)
        unless items.is_a?(Array)
          @host.log_system_safe(run,
            "fan-out: '#{block.fan_out_from}' is #{items.class} (expected Array) on block '#{block.name}' — skipping",
            db_mutex)
          return
        end
        return if items.empty?

        thread_id_template = target_process.thread_id_template
        rate_limit_ms = block.fan_out_rate_limit && block.fan_out_rate_limit["window_ms"].to_i
        rate_limit_n  = block.fan_out_rate_limit && block.fan_out_rate_limit["n"].to_i
        spawned = 0
        skipped = 0

        db_mutex.synchronize do
          jobs_repo = (@jobs_repo ||= Storage::Repositories::Jobs.new(@db))

          items.each_with_index do |item, idx|
            event = build_fan_out_event(item, idx, block.fan_out_maps)
            child_thread_id = if thread_id_template
                                rendered = Prouterd::Util::Templater.render(thread_id_template, { "event" => event })
                                rendered.to_s.strip.empty? ? nil : rendered.to_s.strip
                              end

            if block.fan_out_dedupe && dedupe_skip?(@runs, target_process.name, child_thread_id, block.fan_out_dedupe)
              skipped += 1
              next
            end

            child = @runs.create_run(
              process_name:  target_process.name,
              process_config_commit_id: run.process_config_commit_id,
              input_event:   event,
              parent_run_id: run.id,
              thread_id:     child_thread_id
            )
            available_at = if rate_limit_ms && rate_limit_n.positive?
                             # `rate-limit N/window` → space groups of N
                             # children one window apart. group_idx 0
                             # available now, group_idx 1 after window,
                             # etc.
                             group_idx = spawned / rate_limit_n
                             Time.now + (group_idx * rate_limit_ms / 1000.0)
                           end
            jobs_repo.enqueue(run_id: child.id, kind: "execute", available_at: available_at)
            spawned += 1
          end
          @runs.append_log(
            run_id: run.id, stream: "system",
            content: "fan-out from '#{block.name}.#{block.fan_out_from}' into '#{target_process.name}': " \
                     "#{spawned} child run(s) enqueued#{skipped.positive? ? " (#{skipped} deduped)" : ''}"
          )
        end
      end

      private

      # Project an array element to a child input event. With no maps
      # the element passes through (Hash) or wraps (non-Hash). With
      # maps, only the projected fields appear on the child event;
      # unprojected fields are dropped on purpose so per-child events
      # are minimal.
      def build_fan_out_event(item, idx, maps)
        return (item.is_a?(Hash) ? item : { "value" => item, "index" => idx }) if maps.empty?

        event = {}
        maps.each do |m|
          value = RetryEngine.resolve_dotted_path(item, m["from"])
          if m["filter_prefix"] && value.is_a?(Array)
            prefix = m["filter_prefix"]
            value = value.select { |v| v.is_a?(String) && v.start_with?(prefix) }
            value = value.map { |v| v.sub(/\A#{Regexp.escape(prefix)}/, "") } if m["strip_prefix"]
          end
          event[m["name"]] = value
        end
        event["index"] = idx
        event
      end

      # `dedupe by <field> window <ms> [when prior-run.status eq <s>]`
      # Skips a child if the same {process_name, thread_id} ran within
      # the window (optionally filtered to a specific status).
      def dedupe_skip?(runs_repo, process_name, thread_id, dedupe_spec)
        return false unless thread_id  # without a thread_id key dedupe is undefined

        cutoff = Time.now.utc - (dedupe_spec["window_ms"].to_i / 1000.0)
        rows = runs_repo.list_runs(limit: 50, process_name: process_name, thread_id: thread_id)
        return false if rows.empty?

        rows.any? do |r|
          ts = r.created_at && (Time.parse(r.created_at) rescue nil)
          next false unless ts && ts >= cutoff
          dedupe_spec["when_status"].nil? || r.status == dedupe_spec["when_status"]
        end
      end
    end
  end
end
