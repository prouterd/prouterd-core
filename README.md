# prouterd

A CLI-first process orchestrator. Events flow through declarative routes
into containerized blocks. Configured via a router-style line-oriented
DSL, operated via an interactive shell.

```
sales-prouter-01# show running-config
sales-prouter-01# configure terminal
sales-prouter-01(config)# process lead_pipeline
sales-prouter-01(config-process)# block enrich
sales-prouter-01(config-block)# image registry.local/blocks/enrich:v3
sales-prouter-01(config-block)# timeout 120s
sales-prouter-01(config-block)# exit
sales-prouter-01(config-process)# commit
Commit complete.
```

It feels like configuring a network router; underneath, it's a real
Docker-driven scheduler with persistent commit history, conditional
routing, retries, replay, webhooks, and cron — all behind one CLI.

## Quick start

### Option A — Docker (no Ruby on the host)

```bash
docker build -t prouterd:latest .
docker run --rm -p 8080:8080 \
  -v prouterd-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e PROUTERD_ADMIN_TOKEN=demo \
  prouterd:latest
```

That gets you the HTTP daemon + cron scheduler + worker pool on
`127.0.0.1:8080`. From another shell:

```bash
curl -s http://127.0.0.1:8080/v1/status

# One-shot CLI inside the running container:
docker exec <container> bundle exec ruby exe/prouter exec "show running-config"
```

The `/var/run/docker.sock` mount is required for `type docker` blocks
(which spawn child containers on the host's Docker daemon). Pure
shell-block pipelines don't need it. There's also a `docker-compose.yml`
in the repo for a persistent setup.

### Option B — local Ruby

Requires Ruby ≥ 3.2, Docker daemon (for `type docker` blocks), and
`libsqlite3-dev`.

```bash
git clone <this-repo>
cd prouterd
bundle install
docker pull alpine:latest

# 1. Validate a sample pipeline
bundle exec ruby exe/prouter check examples/01_hello_world.prc

# 2. Apply it as a versioned commit
bundle exec ruby exe/prouter apply examples/01_hello_world.prc \
  --db /tmp/prouterd.db

# 3. Trigger it
echo '{"name":"world"}' > /tmp/event.json
bundle exec ruby exe/prouter trigger process hello \
  input /tmp/event.json --db /tmp/prouterd.db

# 4. Inspect the run
bundle exec ruby exe/prouter exec "show runs" --db /tmp/prouterd.db
```

For the router-style interactive shell:

```bash
bundle exec ruby exe/prouter shell --db /tmp/prouterd.db
process-router> enable
process-router# show running-config
process-router# show runs
process-router# trigger process hello input /tmp/event.json
process-router# exit
```

## The big idea

Replace visual no-code workflow tools with something that scales like
infrastructure: declarative config in version control, isolated
executables (containers), durable run history, and a CLI you can drive
from scripts and tail in tmux.

| Network router    | Process Router        |
|-------------------|-----------------------|
| packet            | event                 |
| interface         | event source          |
| route             | transition rule       |
| running-config    | active config         |
| startup-config    | config after restart  |
| candidate-config  | config before commit  |
| traceroute        | trace event           |
| failover          | retry / fallback      |
| no shutdown       | enable                |

Configuration answers only:

- what receives events
- where they go
- which blocks exist
- how blocks are connected
- which policies apply
- what to do on failure

Business logic lives **inside blocks** (containers), not in the config.

## CLI reference

```
prouter check  <file>                   parse + validate
prouter render <file>                   emit canonical config
prouter apply  <file> [--db PATH]       commit a config snapshot

prouter shell  [--db PATH] [--config FILE] [--runner KIND]
prouter exec   "<cmd>"

prouter trigger process <name> input <file>   synchronous run
prouter trace   event <file> [--interface NAME]   static analysis (no execution)

prouter replay  run <uid> [from <block>]
prouter cancel  run <uid>                soft cancel — between-level halt
prouter diff    <file>                   diff file vs running config
prouter cleanup --older-than 30d [--dry-run] [--batch-size N]
                                         delete terminal runs older than threshold

prouter serve  [--bind ADDR] [--port N] [--workers N]
                                         HTTP daemon: webhooks + cron + /v1 API

prouter version | help
```

### HTTP daemon endpoints

`prouter serve` exposes:

| Endpoint                              | Auth        | Purpose                          |
|---------------------------------------|-------------|----------------------------------|
| `GET  /v1/status`                     | open        | health, commit pointers          |
| `GET  /metrics`                       | open        | Prometheus text format           |
| `POST /i/<interface>`                 | per-iface   | webhook ingestion                |
| `GET  /v1/config/{running,startup,commits[/:id]}` | admin | inspect config history |
| `POST /v1/config/{check,apply,rollback}` | admin    | mutate config                    |
| `GET  /v1/processes[/:name]`          | admin       | list / detail                    |
| `POST /v1/processes/:name/trigger`    | admin       | enqueue a run                    |
| `GET  /v1/runs[?process=&status=]`    | admin       | list                             |
| `GET  /v1/runs/:uid[/logs[?stream=&block=],/artifacts]` | admin | inspect              |
| `POST /v1/runs/:uid/{replay,cancel}`  | admin       | re-run / soft + hard cancel      |
| `POST /v1/trace`                      | admin       | static routing analysis          |

Admin auth: bearer token from `PROUTERD_ADMIN_TOKEN` env var. If unset, /v1/*
routes are open — fine for local dev; the daemon prints a warning.

Graceful shutdown: SIGINT/SIGTERM stops accepting state-changing requests
(503), drains in-flight runs (30s default), then stops Puma.

Common flags:

- `--db PATH`     SQLite path (default `var/prouterd.db`, env `PROUTERD_DB`)
- `--no-db`       skip persistence (in-memory)
- `--config FILE` load this `.prc` file as the running config
- `--runner KIND` `docker` (default) or `stub` (env `PROUTERD_RUNNER`)

### Production env vars

The daemon reads everything operationally tunable from the environment so
secrets and limits don't end up in `.prc` files or `ps` output:

| Var                              | Default       | What it does                                    |
|----------------------------------|---------------|-------------------------------------------------|
| `PROUTERD_ADMIN_TOKEN`            | _(unset → open)_ | Bearer token for `/v1/*`                     |
| `PROUTERD_LOG_LEVEL`              | `info`        | `debug` / `info` / `warn` / `error` / `fatal`   |
| `PROUTERD_SSL_CERT` + `..._KEY`   | _(plain HTTP)_ | PEM cert + key paths for HTTPS                 |
| `PROUTERD_MAX_BODY_BYTES`         | `1048576` (1 MB) | Reject `/i/*` and most `/v1` POSTs above this |
| `PROUTERD_MAX_CONFIG_BYTES`       | `4194304` (4 MB) | Higher cap for `/v1/config/{check,apply}`     |
| `PROUTERD_LOG_CAPTURE_BYTES`      | `1048576` (1 MB) | Per-stream cap on persisted container logs    |
| `PROUTERD_CONTAINER_STOP_TIMEOUT` | `10` (s)      | SIGTERM grace before SIGKILL on cancel          |
| `PROUTERD_JOB_LOCK_TIMEOUT`       | `60` (s)      | Recovery: re-queue job locks older than this    |
| `PROUTERD_WEBHOOK_RATE`           | `60/1`        | `MAX/WINDOW` per-interface webhook rate limit   |
| `PROUTERD_ARTIFACTS_ROOT`         | `var/artifacts` | Where `ArtifactStore` writes block outputs    |
| `PROUTERD_DB`                     | `var/prouterd.db` | SQLite path                                  |
| `PROUTERD_RUNNER`                 | `docker`      | Default for `--runner`                          |

### Production deployment

A hardened invocation: HTTPS, secrets read from disk (Docker Compose /
Kubernetes / systemd-LoadCredential all expose the same shape), capped
log capture, and a generous container-stop window so blocks can flush
output.json before SIGKILL.

```bash
export PROUTERD_ADMIN_TOKEN="$(cat /run/secrets/prouterd_admin)"
export PROUTERD_SSL_CERT=/etc/prouterd/tls/cert.pem
export PROUTERD_SSL_KEY=/etc/prouterd/tls/key.pem
export PROUTERD_LOG_LEVEL=info
export PROUTERD_LOG_CAPTURE_BYTES=4194304       # 4 MB per stream
export PROUTERD_CONTAINER_STOP_TIMEOUT=30       # 30s graceful SIGTERM
export PROUTERD_ARTIFACTS_ROOT=/var/lib/prouterd/artifacts

bundle exec ruby exe/prouter serve \
  --bind 0.0.0.0 --port 8443 \
  --db /var/lib/prouterd/prouterd.db \
  --workers 8
```

For secrets that the daemon must inject into blocks at run time (webhook
tokens, third-party API keys), declare them in the DSL and point at
either an env var or a file the daemon can read:

```prc
secret API_TOKEN
 source file /run/secrets/api_token   ! Docker secret / k8s secret volume
exit
```

A long-running cleanup: split into 500-row transactions so the table
isn't write-locked for minutes on a million-run sweep.

```bash
prouter cleanup --older-than 90d --batch-size 500 \
  --db /var/lib/prouterd/prouterd.db
```

## DSL cheatsheet (`.prc` files)

```prc
! Comments start with ! or #
router demo
 hostname my-router-01
exit

secret WEBHOOK_TOKEN
 source env WEBHOOK_TOKEN              ! reads $WEBHOOK_TOKEN from daemon env
exit
secret API_TOKEN
 source file /run/secrets/api_token    ! Docker/Compose/k8s secret volumes
exit

policy retry_standard
 retry attempts 3
 retry backoff exponential
 retry initial-delay 5s
 retry max-delay 2m
exit

queue default
 concurrency 10
 timeout 10m
exit

interface webhook leads_in
 path /leads
 method POST
 auth bearer secret WEBHOOK_TOKEN
 no shutdown
exit

interface cron daily_report
 schedule "0 9 * * *"
 timezone "Europe/Berlin"
 no shutdown
exit

interface manual cli
 no shutdown
exit

process lead_pipeline
 description "Lead enrichment + sales notification"
 queue default
 no shutdown

 block extract
  type docker
   image registry.local/blocks/extract:v1
  exit
  input event.body
  output lead.raw
  timeout 30s
  enable
 exit

 block normalize
  type shell
   exec "ruby blocks/normalize/app.rb"
   cwd ./blocks/normalize
  exit
  input lead.raw
  output lead.normalized
  timeout 20s
  enable
 exit

 block score
  type docker
   image registry.local/blocks/score:v2
  exit
  input lead.normalized
  output lead.scored
  timeout 20s
  retry retry_standard
  enable
 exit

 block notify_sales
  type docker
   image registry.local/blocks/notify-sales:v1
  exit
  input lead.scored
  output sales.notified
  timeout 15s
  secret WEBHOOK_TOKEN
  enable
 exit

 ! short-form route (no conditions)
 route extract normalize
 route normalize score

 ! long-form route with match conditions
 route score notify_sales
  match lead.scored.score gt 70
 exit
exit

route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
```

### Block execution types (spec §2-§5)

Every block declares its runner via a `type` sub-section. Built-in:

- `type docker` — runs in a container via `DockerRunner`.
  Fields: `image` (required), `command`, `pull`, `network`, `user`,
  `memory`, `cpu`.
- `type shell` — runs as a host process via `ShellRunner`.
  Fields: `exec` (required), `cwd`, `shell`, `env KEY VALUE`.

Same `/prouter/{input.json,output.json,artifacts/}` contract for both.
The orchestrator dispatches per-block, so pipelines can mix types
freely. Pre-Phase-12 inline form (`image foo` directly in the block)
still parses — `execution_type=docker` is auto-inferred.

**Adding your own runner type** is a single plugin file + a single
`Runner` class — parser/validator/renderer/show/CLI all discover the
type via `Runner::Registry`, so the core has zero hardcoded type names.
See the "Adding a new runner type" section in
[CLAUDE.md](CLAUDE.md#adding-a-new-runner-type) for the worked recipe.
The reference test [`spec/prouterd/runner/plugin_spec.rb`](spec/prouterd/runner/plugin_spec.rb)
defines a fake `printer` plugin in-test and exercises parse → validate
→ render → orchestrate end-to-end on it.

### Match operators

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `exists`, `in`. Multiple matches
within one route AND together. There is no OR — use a separate route.

### Block contract (spec §10)

The runner mounts a per-step directory at `/prouter` inside the container:

| Path                         | Direction | Purpose                              |
|------------------------------|-----------|--------------------------------------|
| `/prouter/input.json`        | read      | run_id, process, block, input, ctx   |
| `/prouter/output.json`       | write     | block's result (REQUIRED on success) |
| `/prouter/artifacts/`        | write     | files to archive                     |

Environment variables: `PROUTER_RUN_ID`, `PROUTER_PROCESS_NAME`,
`PROUTER_BLOCK_NAME`, `PROUTER_ATTEMPT`, `PROUTER_INPUT_PATH`,
`PROUTER_OUTPUT_PATH`, `PROUTER_ARTIFACTS_DIR`, plus every secret declared
on the block.

A block succeeds iff `exit_code == 0` AND `/prouter/output.json` exists
AND parses as valid JSON.

## Architecture

```
lib/prouterd/
  config/         lexer, parser, AST, validator, renderer
  shell/          mode stack (>, #, config, config-process, config-block)
  storage/        SQLite + migrations + repositories
  control_plane/  ConfigStore (commit/rollback/write_memory)
  runner/         Plugin/Registry, DockerRunner, ShellRunner, StubRunner,
                  plugins/{docker,shell}.rb
  runtime/        Orchestrator, Context, MatchEvaluator, ContractValidator,
                  RetryCalculator, Redactor, Recovery, Tracer, Scheduler,
                  WorkerPool, InFlightRegistry
  api/            Rack app + WebhookHandler + Puma launcher
  cli/main.rb     prouter binary
exe/prouter       executable
```

Storage schema (SQLite, WAL):

- `config_commits` + `config_pointers` (running, startup)
- `runs`, `run_steps`, `run_logs`, `artifacts`
- `schema_migrations`

## Running tests

```bash
bundle exec rspec
```

494 specs cover lexer/parser/validator/renderer, shell flows + router-style
tab completion, storage repositories, ConfigStore lifecycle, orchestrator
with stub runner, match evaluator, contract validation, retry/replay/
cancel/diff/scheduler, webhook handler, IPC events bus + WebSocket
endpoints, plugin registration end-to-end on a fake runner type, the
structured logger, body-size enforcement, secret resolvers (env + file),
rate-limiter eviction, log-capture cap, and a full
apply→trigger→replay→rollback integration test.

The Docker-dependent paths are tested with a `StubRunner`. To exercise
real Docker, the `examples/` scripts run pipelines against `alpine:latest`
end-to-end.

## Status

Implemented (all of [the spec][] §28 acceptance criteria):

- ✅ Config language: lexer/parser/AST/validator/canonical renderer
- ✅ router-style shell with running/candidate/startup configs
- ✅ Persistent commit history, rollback, `write memory`, audit trail
- ✅ Docker block execution, run/step/log/artifact persistence
- ✅ Match conditions, parallel branching, sequential queue
- ✅ Retry policies (fixed/exp/linear backoff), on-failure stop/continue
- ✅ Replay run + replay from block (context-seeded)
- ✅ Soft + hard cancel (kills in-flight container via in-flight registry)
- ✅ `diff <file> running-config`
- ✅ Webhooks (HTTP daemon, bearer auth, async dispatch, method enforcement)
- ✅ Cron scheduler (fugit, timezone-aware)
- ✅ Crash recovery sweep at daemon start
- ✅ Secret redaction in logs/errors
- ✅ /v1 HTTP API for runs/configs/processes/traces (admin bearer auth)
- ✅ /metrics Prometheus endpoint (counters + gauges)
- ✅ Graceful shutdown: 503 + in-flight drain
- ✅ `cleanup --older-than` retention sweep
- ✅ Persistent SQLite-backed job queue + worker pool (`--workers N`),
  daemon crash mid-run is recovered on next boot
- ✅ Reline (history + line editing) in interactive shell
- ✅ Per-interface webhook rate limiting (`PROUTERD_WEBHOOK_RATE`)
- ✅ Block execution types: `type docker` and `type shell` runners
  dispatched per-block; mixed pipelines work transparently
- ✅ Pluggable runner types via `Runner::Plugin` — third-party gems can
  register new `type <foo>` keywords without forking the core
- ✅ Output contract validation (`contract <name>` with type/range/
  format/pattern/enum constraints, `on violation fail|retry|warn`)
- ✅ Production hardening: structured Logger, request body limits
  (1 MB / 4 MB for config), HTTPS via Puma SSL, chunked artifact
  download, capped container log capture, graceful container stop
  (SIGTERM → SIGKILL with timeout), `RateLimiter` bucket eviction,
  file-based secrets (`source file /run/secrets/x`), batched
  `cleanup`, `PROUTERD_ARTIFACTS_ROOT` / `PROUTERD_JOB_LOCK_TIMEOUT` /
  `PROUTERD_LOG_LEVEL` env knobs

Deliberately out of v0.1 scope (per spec §31, "workable without these for now"):

- ☐ KubernetesRunner / LambdaRunner / ... (the plugin interface is
  ready — write a plugin file and a Runner class, no core edits)
- ☐ S3 / object-store artifacts (`ArtifactStore` interface ready)
- ☐ Vault / AWS Secrets Manager (write a class with `#resolve(secret)`,
  inject via `secret_resolver:` — env + file are built-in)
- ☐ RBAC / mTLS / OIDC (basic admin bearer is in; HTTPS is on)
- ☐ Postgres adapter (`Storage::DB` abstraction ready)
- ☐ Idempotency keys
- ☐ Web UI

[the spec]: spec.md
