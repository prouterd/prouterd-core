require "json"

module Prouterd
  module API
    # Handlers for the /v1/* endpoints from spec §22.2. Each method matches
    # a route from `App#dispatch_v1` and returns a Rack response triple.
    #
    # Endpoints that mutate state (config apply, run replay/cancel, trigger)
    # require the admin bearer when PROUTERD_ADMIN_TOKEN is configured.
    # Read-only endpoints follow the same auth rule for symmetry — there is
    # no PII concern, but a daemon might still not want random observers.
    #
    # All bodies are JSON. Response shape conventions:
    #   { "data": ..., "meta": { ... } }   on success
    #   { "error": "...", "details": [..] } on failure
    class V1
      def initialize(store:, runner:, secret_resolver:, in_flight:, metrics:, jobs:, logger: nil)
        @store = store
        @runner = runner
        @secret_resolver = secret_resolver
        @in_flight = in_flight
        @metrics = metrics
        @logger = logger
        @jobs = jobs
      end

      # ----- /v1/config -----

      def get_config_running(_request)
        text = Config::Renderer.render(@store.load_running)
        plain(200, text)
      end

      def get_config_startup(_request)
        commit = @store.startup_commit
        return json(404, error: "startup-config not set") unless commit

        plain(200, commit.rendered_config)
      end

      def post_config_check(request)
        body = read_body(request) or return json(400, error: "missing body")
        document = parse_dsl_or_error(body) or return json(400, error: "could not parse")
        result = Config::Validator.validate(document)
        json(result.valid? ? 200 : 422, {
          valid: result.valid?,
          errors: result.errors.map { |e| { line: e.line, message: e.message } },
          warnings: result.warnings.map { |w| { line: w.line, message: w.message } }
        })
      rescue Config::ConfigError => e
        json(400, error: e.message, line: e.line)
      end

      def post_config_apply(request)
        body = read_body(request) or return json(400, error: "missing body")
        author = request.get_header("HTTP_X_AUTHOR") || ENV["USER"]
        message = request.get_header("HTTP_X_COMMIT_MESSAGE") || "apply via /v1"

        document = parse_dsl_or_error(body) or return json(400, error: "could not parse")
        result = Config::Validator.validate(document)
        return json(422, error: "validation failed", details: result.errors.map(&:message)) unless result.valid?

        commit = @store.commit(document, author: author, message: message)
        json(201, data: { commit_id: commit.id, checksum: commit.checksum })
      rescue Config::ConfigError => e
        json(400, error: e.message, line: e.line)
      end

      def post_config_rollback(request)
        body = parse_json_body(request) or return json(400, error: "expected JSON body")
        commit_id = body["commit_id"]
        return json(400, error: "missing commit_id") unless commit_id.is_a?(Integer)

        commit = @store.rollback(commit_id)
        json(200, data: { commit_id: commit.id, checksum: commit.checksum })
      rescue ControlPlane::ConfigStoreError => e
        json(404, error: e.message)
      end

      # Mark the running config as the boot config (router CLI's `write memory`).
      # Returns the commit that's now blessed as boot. 409 when there is no
      # running pointer to copy.
      def post_config_save_boot(_request)
        commit = @store.write_memory
        json(200, data: { commit_id: commit.id, checksum: commit.checksum })
      rescue ControlPlane::ConfigStoreError => e
        json(409, error: e.message)
      end

      def get_config_commits(_request)
        commits = @store.list_commits(limit: 100).map { |c| commit_summary(c) }
        running = @store.running_commit&.id
        startup = @store.startup_commit&.id
        json(200, data: commits, meta: { running: running, startup: startup })
      end

      def get_config_commit(_request, id)
        commit = @store.get_commit(id.to_i)
        return json(404, error: "no such commit") unless commit

        json(200, data: commit_summary(commit).merge(rendered_config: commit.rendered_config))
      end

      # ----- /v1/{interfaces,queues,policies,secrets} -----

      def get_interfaces(_request)
        document = @store.load_running
        json(200, data: document.interfaces.map { |i| interface_summary(i) })
      end

      def get_queues(_request)
        document = @store.load_running
        json(200, data: document.queues.map { |q| queue_summary(q) })
      end

      def get_policies(_request)
        document = @store.load_running
        json(200, data: document.policies.map { |p| policy_summary(p) })
      end

      # Spec §22.6 / spec §37.1: secret values must never be exposed via the
      # API. We return the declared name, source type, and source ref (e.g.
      # an env var NAME, never its value), plus a "present"/"missing" status
      # for env-backed secrets so operators can verify configuration without
      # the value crossing the wire.
      def get_secrets(_request)
        document = @store.load_running
        used = secret_usage_index(document)
        json(200, data: document.secrets.map { |s| secret_summary(s, used[s.name] || []) })
      end

      # ----- /v1/processes -----

      def get_processes(_request)
        document = @store.load_running
        json(200, data: document.processes.map { |p| process_summary(p) })
      end

      def get_process(_request, name)
        process = @store.load_running.processes.find { |p| p.name == name }
        return json(404, error: "no such process '#{name}'") unless process

        json(200, data: process_detail(process))
      end

      def post_process_trigger(request, name)
        document = @store.load_running
        process = document.processes.find { |p| p.name == name }
        return json(404, error: "no such process '#{name}'") unless process

        event = parse_json_body(request) || {}
        orchestrator = build_orchestrator
        run = orchestrator.enqueue(
          document, name,
          input_event: event,
          interface_name: nil,
          commit_id: @store.running_commit&.id
        )
        dispatch_run(run)
        @metrics&.increment(:webhooks_received_total, interface: "(api-trigger)", code: 202)

        json(202, data: { run_id: run.uid, status: "queued" })
      end

      # ----- /v1/runs -----

      def get_runs(request)
        process = request.params["process"]
        status = request.params["status"]
        limit = (request.params["limit"] || "50").to_i.clamp(1, 1000)
        offset = (request.params["offset"] || "0").to_i.clamp(0, 100_000)

        repo = Storage::Repositories::Runs.new(@store.db)
        runs = repo.list_runs(limit: limit, offset: offset, process_name: process, status: status)
        json(200, data: runs.map { |r| run_summary(r) })
      end

      def get_run(_request, uid)
        run = run_by_uid(uid) or return json(404, error: "no such run")
        repo = Storage::Repositories::Runs.new(@store.db)
        steps = repo.list_steps(run.id).map { |s| step_summary(s) }
        json(200, data: run_summary(run).merge(steps: steps))
      end

      def get_run_logs(request, uid)
        run = run_by_uid(uid) or return json(404, error: "no such run")
        block = request.params["block"]
        stream = request.params["stream"]

        repo = Storage::Repositories::Runs.new(@store.db)
        step_id = nil
        if block
          step = repo.list_steps(run.id).find { |s| s.block_name == block }
          return json(404, error: "no such block '#{block}' in run") unless step

          step_id = step.id
        end

        logs = repo.list_logs(run.id, step_id: step_id)
        logs = logs.select { |l| l.stream == stream } if stream
        json(200, data: logs.map { |l| log_summary(l) })
      end

      # GET /v1/artifacts/:id/download — stream the persisted bytes to the
      # caller. Path is read from the artifacts row server-side; the client
      # never gets to specify it (closed against directory traversal).
      def get_artifact_download(_request, id)
        repo = Storage::Repositories::Runs.new(@store.db)
        artifact = repo.get_artifact(id.to_i)
        return json(404, error: "no such artifact") unless artifact
        return json(410, error: "artifact bytes no longer on disk") unless File.file?(artifact.path)

        headers = {
          "content-type"        => artifact.content_type || "application/octet-stream",
          "content-length"      => artifact.size_bytes.to_s,
          "content-disposition" => %(attachment; filename="#{artifact.name.to_s.gsub(/"/, "")}")
        }
        [200, headers, [File.binread(artifact.path)]]
      end

      def get_run_artifacts(_request, uid)
        run = run_by_uid(uid) or return json(404, error: "no such run")
        repo = Storage::Repositories::Runs.new(@store.db)
        json(200, data: repo.list_artifacts(run.id).map { |a| artifact_summary(a) })
      end

      def post_run_replay(request, uid)
        original = run_by_uid(uid) or return json(404, error: "no such run")
        unless original.process_config_commit_id
          return json(422, error: "run not pinned to a commit")
        end
        body = parse_json_body(request) || {}
        from_block = body["from_block"]

        commit = @store.get_commit(original.process_config_commit_id)
        return json(410, error: "config commit no longer exists") unless commit

        document = Config::Parser.parse(Config::Lexer.tokenize(commit.rendered_config))
        orchestrator = build_orchestrator

        if from_block
          repo = Storage::Repositories::Runs.new(@store.db)
          target_step = repo.list_steps(original.id).find { |s| s.block_name == from_block }
          return json(404, error: "block '#{from_block}' did not run in original") unless target_step
          payload = JSON.parse(target_step.input_json || "{}")
          seed = payload["context"] || {}

          new_run = orchestrator.enqueue(
            document, original.process_name,
            input_event: payload["context"]&.dig("event") ||
                         (original.input_event_json ? JSON.parse(original.input_event_json) : {}),
            interface_name: original.interface_name,
            commit_id: original.process_config_commit_id,
            replay_of_run_id: original.id
          )
          dispatch_run(new_run, from_block: from_block, seed_context: seed)
        else
          new_run = orchestrator.enqueue(
            document, original.process_name,
            input_event: original.input_event_json ? JSON.parse(original.input_event_json) : {},
            interface_name: original.interface_name,
            commit_id: original.process_config_commit_id,
            replay_of_run_id: original.id
          )
          dispatch_run(new_run)
        end

        json(202, data: { run_id: new_run.uid, status: "queued", replay_of: uid, from: from_block })
      end

      def post_run_cancel(_request, uid)
        run = run_by_uid(uid) or return json(404, error: "no such run")
        if %w[success failed canceled].include?(run.status)
          return json(409, error: "run already #{run.status}")
        end

        repo = Storage::Repositories::Runs.new(@store.db)
        finished_at = Time.now.utc.iso8601(3)
        repo.update_run(run.id, status: "canceled", finished_at: finished_at, error_summary: "canceled via API")
        repo.list_steps(run.id).each do |s|
          next if %w[success failed canceled timeout skipped].include?(s.status)

          repo.update_step(s.id, status: "canceled", finished_at: finished_at,
                                 error_type: "canceled", error_message: "canceled via API")
        end

        # Hard-cancel: if the daemon's runner attached containers for this run,
        # kill them. The orchestrator's between-level poll picks up the
        # status flip and aborts further scheduling.
        killed = []
        if @in_flight
          @in_flight.container_ids_for(run.uid).each do |cid|
            begin
              container = Docker::Container.get(cid)
              container.kill rescue nil
              killed << cid
            rescue StandardError
              # container may already be gone
            end
          end
        end

        json(200, data: { run_id: run.uid, status: "canceled", killed_containers: killed })
      end

      # ----- /v1/trace -----

      def post_trace(request)
        body = parse_json_body(request) || {}
        event = body["event"] || {}
        interface = body["interface"]

        document = @store.load_running
        result = Runtime::Tracer.trace(document, event, interface_name: interface)
        json(200, data: trace_to_payload(result))
      end

      private

      def build_orchestrator
        Runtime::Orchestrator.new(
          db: @store.db,
          runner: @runner,
          secret_resolver: @secret_resolver,
          in_flight: @in_flight,
          metrics: @metrics
        )
      end

      # Enqueue a previously-created Run onto the durable JobQueue. The
      # WorkerPool drains the queue; daemon crash mid-run is recoverable.
      def dispatch_run(run, from_block: nil, seed_context: nil)
        if from_block
          @jobs.enqueue(
            run_id: run.id, kind: "execute_from_block",
            payload: { "from_block" => from_block, "seed_context" => seed_context || {} }
          )
        else
          @jobs.enqueue(run_id: run.id, kind: "execute")
        end
      end

      def run_by_uid(uid)
        Storage::Repositories::Runs.new(@store.db).get_run_by_uid(uid)
      end

      def commit_summary(commit)
        {
          id: commit.id,
          checksum: commit.checksum,
          author: commit.author,
          message: commit.message,
          created_at: commit.created_at
        }
      end

      def process_summary(p)
        {
          name: p.name,
          description: p.description,
          queue: p.queue_name,
          shutdown: p.shutdown,
          blocks: p.blocks.length,
          routes: p.routes.length
        }
      end

      def process_detail(p)
        {
          name: p.name,
          description: p.description,
          queue: p.queue_name,
          shutdown: p.shutdown,
          blocks: p.blocks.map { |b| { name: b.name, image: b.image, timeout_ms: b.timeout_ms,
                                       retry_policy: b.retry_policy_name, input: b.input, output: b.output,
                                       network: b.network, shutdown: b.shutdown } },
          routes: p.routes.map { |r| { from: r.from_block, to: r.to_block,
                                       on_failure: r.on_failure,
                                       matches: r.matches.map { |m| match_summary(m) } } }
        }
      end

      def match_summary(m)
        { path: m.path, operator: m.operator, values: m.values }
      end

      def interface_summary(i)
        {
          name:     i.name,
          type:     i.type,
          shutdown: i.shutdown,
          path:     i.respond_to?(:path)   ? i.path   : nil,
          method:   i.respond_to?(:method) ? i.method : nil,
          schedule: i.respond_to?(:schedule) ? i.schedule : nil,
          timezone: i.respond_to?(:timezone) ? i.timezone : nil
        }.compact
      end

      def queue_summary(q)
        { name: q.name, concurrency: q.concurrency, timeout_ms: q.timeout_ms }
      end

      def policy_summary(p)
        {
          name:                   p.name,
          retry_attempts:         p.retry_attempts,
          retry_backoff:          p.retry_backoff,
          retry_initial_delay_ms: p.retry_initial_delay_ms,
          retry_max_delay_ms:     p.retry_max_delay_ms,
          timeout_ms:             p.timeout_ms
        }
      end

      def secret_summary(s, used_by)
        {
          name:        s.name,
          source_type: s.source_type,
          source_ref:  s.source_value,
          used_by:     used_by,
          status:      secret_status(s)
        }
      end

      def secret_status(secret)
        case secret.source_type
        when "env" then ENV.key?(secret.source_value.to_s) ? "present" : "missing"
        else "unknown"
        end
      end

      def secret_usage_index(document)
        idx = Hash.new { |h, k| h[k] = [] }
        document.processes.each do |p|
          p.blocks.each do |b|
            Array(b.secret_names).each { |n| idx[n] << "block #{b.name}" }
          end
        end
        document.interfaces.each do |iface|
          if iface.respond_to?(:auth) && iface.auth && iface.auth.respond_to?(:secret_name) && iface.auth.secret_name
            idx[iface.auth.secret_name] << "interface #{iface.name}"
          end
        end
        idx
      end

      def run_summary(r)
        {
          uid: r.uid,
          process_name: r.process_name,
          interface_name: r.interface_name,
          status: r.status,
          commit_id: r.process_config_commit_id,
          replay_of: r.replay_of_run_id,    # numeric, kept for back-compat
          replay_of_uid: r.replay_of_uid,   # human-friendly, recommended
          started_at: r.started_at,
          finished_at: r.finished_at,
          created_at: r.created_at,
          duration_ms: r.duration_ms,
          error_summary: r.error_summary
        }
      end

      def step_summary(s)
        {
          id: s.id,
          block_name: s.block_name,
          status: s.status,
          attempt: s.attempt,
          image: s.image,
          exit_code: s.exit_code,
          error_type: s.error_type,
          error_message: s.error_message,
          duration_ms: s.duration_ms,
          started_at: s.started_at,
          finished_at: s.finished_at
        }
      end

      def log_summary(l)
        { id: l.id, step_id: l.step_id, stream: l.stream, content: l.content, created_at: l.created_at }
      end

      def artifact_summary(a)
        {
          id: a.id, block_name: a.block_name, name: a.name, path: a.path,
          size_bytes: a.size_bytes, checksum: a.checksum, content_type: a.content_type,
          created_at: a.created_at
        }
      end

      def trace_to_payload(result)
        {
          interface: result.interface,
          process: result.process,
          global_route_matched: result.global_route_passes,
          edges: result.graph.map do |e|
            {
              from: e.from, to: e.to,
              passes: e.passes,
              matches: e.match_results.map { |m| { path: m.path, operator: m.operator, values: m.values, result: m.result } }
            }
          end,
          policies: result.policies,
          warnings: result.warnings,
          error: result.error
        }
      end

      def parse_dsl_or_error(body)
        Config::Parser.parse(Config::Lexer.tokenize(body))
      end

      def read_body(request)
        text = request.body&.read.to_s
        text.empty? ? nil : text
      end

      def parse_json_body(request)
        text = read_body(request)
        return nil unless text

        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      def json(status, payload)
        [status, { "content-type" => "application/json" }, [JSON.dump(payload)]]
      end

      def plain(status, text)
        [status, { "content-type" => "text/plain; charset=utf-8" }, [text]]
      end
    end
  end
end
