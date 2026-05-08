require "json"
require "securerandom"
require "time"

module Prouterd
  module Runtime
    # Pool of worker threads that drain the jobs queue. Lives inside the
    # daemon process started by `prouter serve`.
    #
    # Each worker:
    #   1. claims a job atomically (UPDATE … RETURNING),
    #   2. loads the run + its pinned config commit,
    #   3. dispatches to Orchestrator.execute_run with kwargs from the job
    #      payload (`from_block`, `seed_context`),
    #   4. marks the job completed/failed.
    #
    # On daemon crash mid-run, the locked job stays locked. The next daemon
    # boot's Recovery sweep flips it back to queued (heartbeat-style timeout)
    # and a worker picks it up. The block author is responsible for
    # idempotency — partial steps from the previous run remain in DB but the
    # orchestrator restarts from entry blocks (or `from_block` if specified).
    class WorkerPool
      DEFAULT_WORKERS = 4
      POLL_INTERVAL = 0.25

      def initialize(store:, runner:, in_flight: nil, metrics: nil,
                     workers: DEFAULT_WORKERS, logger: NullLogger.new,
                     mcp_pool: nil)
        @store = store
        @runner = runner
        @in_flight = in_flight
        @metrics = metrics
        @workers = workers
        @logger = logger
        @mcp_pool = mcp_pool
        @threads = []
        @stopping = false
        @worker_id_prefix = "worker-#{SecureRandom.hex(2)}"
      end

      def run
        @logger.info("worker-pool starting",
                     facility: "WORK", mnemonic: "STARTING",
                     workers: @workers)
        @workers.times do |i|
          @threads << Thread.new { worker_loop("#{@worker_id_prefix}-#{i}") }
        end
      end

      def stop
        @stopping = true
        @threads.each(&:join)
      end

      private

      def worker_loop(worker_id)
        jobs = Storage::Repositories::Jobs.new(@store.db)
        until @stopping
          begin
            job = jobs.claim(worker_id)
            if job
              process_job(job, worker_id, jobs)
            else
              sleep POLL_INTERVAL
            end
          rescue StandardError => e
            @logger.error("claim error",
                          facility: "WORK", mnemonic: "CLAIM_ERR",
                          worker: worker_id, error: e.class.name, message: e.message)
            sleep POLL_INTERVAL
          end
        end
      end

      def process_job(job, worker_id, jobs)
        runs_repo = Storage::Repositories::Runs.new(@store.db)
        run = runs_repo.get_run(job.run_id)
        unless run
          jobs.fail(job.id, "run #{job.run_id} no longer exists")
          return
        end

        # Skip if user already canceled the run between enqueue and claim.
        if run.status == "canceled"
          jobs.complete(job.id)
          return
        end

        document = load_document(run)
        unless document
          jobs.fail(job.id, "config commit #{run.process_config_commit_id || '(none)'} unavailable")
          runs_repo.update_run(run.id, status: "failed", finished_at: Time.now.utc.iso8601(3),
                                       error_summary: "config commit unavailable on worker dispatch")
          return
        end

        orchestrator = Orchestrator.new(
          db: @store.db, runner: @runner,
          in_flight: @in_flight, metrics: @metrics,
          mcp_pool: @mcp_pool
        )

        kwargs = build_execute_kwargs(job)
        orchestrator.execute_run(run, document, **kwargs)
        jobs.complete(job.id)
      rescue StandardError => e
        @logger.error("run crashed",
                      facility: "WORK", mnemonic: "RUN_CRASHED",
                      worker: worker_id, run_id: job.run_id,
                      error: e.class.name, message: e.message)
        runs_repo&.update_run(
          job.run_id,
          status: "failed",
          finished_at: Time.now.utc.iso8601(3),
          error_summary: "worker crash: #{e.class}: #{e.message}"
        )
        jobs.fail(job.id, "#{e.class}: #{e.message}")
      end

      def load_document(run)
        if run.process_config_commit_id
          commit = @store.get_commit(run.process_config_commit_id)
          return nil unless commit

          Config::Parser.parse(Config::Lexer.tokenize(commit.rendered_config))
        else
          @store.load_running
        end
      end

      def build_execute_kwargs(job)
        return {} if job.kind == "execute"

        payload = job.payload
        if job.kind == "execute_from_block"
          {
            from_block: payload["from_block"],
            seed_context: payload["seed_context"] || {}
          }
        else
          {}
        end
      end
    end
  end
end
