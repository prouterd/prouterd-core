# Changelog

## v0.1 — 2026-05-02

### Phase 1: .prc config language
- Line-oriented lexer with quoted strings, comments, line/column tracking
- Recursive parser with `exit`-bounded sections for router / secret /
  policy / queue / interface / process / block / route
- AST + validator (refs, cycles, multi-incoming, missing image, entry blocks)
- Canonical renderer (idempotent under parse→render→parse)
- `prouter check` and `prouter render` CLI

### Phase 2: router-style interactive shell
- Mode stack: user `>`, privileged `#`, config `(config)#`,
  config-process, config-block, plus per-section sub-modes
- Candidate-config flow with `commit` / `abort` / `exit`
- `show` subsystem (running-config, processes, interfaces, etc.)
- `prouter shell` + `prouter exec`

### Phase 3: SQLite-backed config lifecycle
- Schema 0001: `config_commits`, `config_pointers` (running, startup)
- ConfigStore facade: commit / rollback / write_memory / load_running
- `prouter apply` non-interactive commit
- `--db PATH` flag everywhere; `PROUTERD_DB` env

### Phase 4: Runtime core
- Schema 0002: `runs`, `run_steps`, `run_logs`, `artifacts`
- `Runner` adapter with `DockerRunner` (real, via docker-api) +
  `StubRunner` (test fixture)
- Orchestrator: DAG walk from entry blocks, Context dotted-paths,
  per-block input/output/artifacts, secret env resolution
- `prouter trigger`, show runs/run/logs/artifacts
- ArtifactStore (filesystem, S3-ready interface)
- Lexer fix: `String.new` defaults to ASCII-8BIT, breaks SQLite TEXT
  parameterized queries — strings now constructed UTF-8

### Phase 5: Routes and conditions
- MatchEvaluator: 8 operators (`eq`/`neq`/`gt`/`gte`/`lt`/`lte`/`exists`/`in`)
- Level-by-level parallel execution via threads + per-run mutexes
- Tracer: static "what would happen" walk with runtime-dependent
  annotations; TracerRenderer renders spec §16 text format
- `prouter trace event <file>`
- Renderer fix: `command` always quoted (preserves shell metacharacters
  through render→parse roundtrip)

### Phase 6: Retries, on-failure, dead-letter, replay
- RetryCalculator (fixed/exponential/linear backoff with max-delay cap)
- Per-attempt step rows, "retrying" system log lines between attempts
- on-failure stop / continue (per-route) — failed branches can be pruned
  while others proceed
- `show dead-letter`, `prouter replay run <uid>`
- Replay re-executes against the run's PINNED config commit (not current
  running) so behavior is reproducible

### Phase 7: Webhook HTTP daemon
- Rack 3 + Puma, `prouter serve [--bind --port --db --runner]`
- `POST /i/<interface_name>` with bearer auth (constant-time compare)
- `GET /v1/status` health endpoint
- Async dispatch (Thread.new — Phase 11 replaces with worker pool)

### Phase 8: Replay-from-block, crash recovery, redaction
- `replay run <uid> from <block>` — seeds context from captured
  step.input_json["context"] and starts orchestrator at named block
- Recovery sweep on daemon boot: orphaned `running`/`queued` runs and
  steps marked failed
- Redactor scrubs every declared secret value from logs / error_summary
  / step.error_message before persistence

### Phase 9: cancel, diff, cron
- `cancel run <uid>` — soft cancel via run.status=canceled, orchestrator
  polls between levels
- `diff <file> running-config` — shows what would change
- Cron scheduler (fugit) inside `prouter serve` — fires `interface cron`
  declarations at their schedule

### Phase 10: Production hardening
- Full `/v1/*` HTTP API (config, processes, runs, logs, artifacts,
  trace, replay, cancel) with admin bearer auth from `PROUTERD_ADMIN_TOKEN`
- `/metrics` Prometheus text format (counters + uptime + in_flight gauge)
- InFlightRegistry tracks `run_uid → container_id`; `POST /v1/runs/:uid/cancel`
  hard-kills attached Docker containers
- Graceful shutdown: app.stop_accepting → drain registry → puma.stop(true)
- Webhook `method` field actually enforced (405 + Allow header on mismatch)
- `prouter cleanup --older-than 30d [--dry-run]` retention sweep
- LICENSE (MIT)
- DB encoding fix at `Storage::DB#execute` — Rack path segments arrive
  ASCII-8BIT, normalized to UTF-8 at the bind layer (defense-in-depth)

### Phase 11: Persistent job queue + crash-survivable in-flight runs
- Schema 0003: `jobs` table with status / locked_by / locked_at /
  available_at / attempts / payload_json
- Repositories::Jobs with atomic `claim` (UPDATE … RETURNING) — race-free
  under SQLite WAL even with N workers
- Runtime::WorkerPool: configurable thread count (`--workers N`,
  default 4) drains the queue
- Webhook handler / `/v1/processes/:name/trigger` / `/v1/runs/:uid/replay` /
  cron scheduler all enqueue jobs instead of spawning Thread.new
- Recovery extended: locked jobs older than 60s are re-queued at daemon
  boot — daemon crash mid-run no longer drops work
- `Reline` in interactive shell (history + line editing) when available
- `RateLimiter` per webhook interface (sliding window, default 60/sec,
  override via `PROUTERD_WEBHOOK_RATE=MAX/WINDOW`)
- CHANGELOG (this file)

## Status

- 11 phases shipped, one git commit per phase
- 321+ RSpec specs, 0 failures
- All spec §28 acceptance criteria + production hardening
- End-to-end smoke-tested against real Docker + Puma + cron
