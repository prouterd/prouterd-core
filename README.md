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

Requires Ruby ≥ 3.2, Docker daemon, and `libsqlite3-dev`.

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

prouter serve  [--bind ADDR] [--port N]  HTTP daemon + cron scheduler

prouter version | help
```

Common flags:

- `--db PATH`     SQLite path (default `var/prouterd.db`, env `PROUTERD_DB`)
- `--no-db`       skip persistence (in-memory)
- `--config FILE` load this `.prc` file as the running config
- `--runner KIND` `docker` (default) or `stub` (env `PROUTERD_RUNNER`)

## DSL cheatsheet (`.prc` files)

```prc
! Comments start with ! or #
router demo
 hostname my-router-01
exit

secret WEBHOOK_TOKEN
 source env WEBHOOK_TOKEN
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
  image registry.local/blocks/extract:v1
  timeout 30s
  input event.body
  output lead.raw
 exit

 block score
  image registry.local/blocks/score:v2
  timeout 20s
  retry policy retry_standard
  input lead.raw
  output lead.scored
 exit

 block notify_sales
  image registry.local/blocks/notify-sales:v1
  timeout 15s
  secret WEBHOOK_TOKEN
  input lead.scored
  output sales.notified
 exit

 ! short-form route (no conditions)
 route extract score

 ! long-form route with match conditions
 route score notify_sales
  match lead.scored.score gt 70
 exit
exit

route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
```

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
  runner/         DockerRunner + StubRunner
  runtime/        Orchestrator, Context, MatchEvaluator,
                  RetryCalculator, Redactor, Recovery, Tracer, Scheduler
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

281 specs cover lexer/parser/validator/renderer, shell flows, storage
repositories, ConfigStore lifecycle, orchestrator with stub runner,
match evaluator, retry/replay/cancel/diff/scheduler, webhook handler,
and a full apply→trigger→replay→rollback integration test.

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
- ✅ Soft cancel + diff <file> running-config
- ✅ Webhooks (HTTP daemon, bearer auth, async dispatch)
- ✅ Cron scheduler (fugit, timezone-aware)
- ✅ Crash recovery sweep at daemon start
- ✅ Secret redaction in logs/errors

Deliberately out of v0.1 scope (per spec §31, "workable without these for now"):

- ☐ DB-backed worker pool with cross-restart in-flight recovery
- ☐ Hard cancel (kill in-flight containers)
- ☐ KubernetesRunner (`Runner` interface ready)
- ☐ S3 / object-store artifacts (`ArtifactStore` interface ready)
- ☐ RBAC, mTLS, OIDC, audit-per-user
- ☐ Postgres adapter (`Storage::DB` abstraction ready)
- ☐ Idempotency keys, output schema validation
- ☐ Web UI

[the spec]: spec.md
