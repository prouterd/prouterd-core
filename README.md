# prouterd

A CLI-first process orchestrator. Events flow through declarative
routes into executable blocks. Configured via a router-style
line-oriented DSL, operated via an interactive shell.

```
sales-prouter-01# show running-config
sales-prouter-01# configure terminal
sales-prouter-01(config)# interface docker enricher
sales-prouter-01(config-iface)# image registry.local/blocks/enrich:v3
sales-prouter-01(config-iface)# exit
sales-prouter-01(config)# process lead_pipeline
sales-prouter-01(config-process)# block enrich
sales-prouter-01(config-block)# interface docker enricher
sales-prouter-01(config-block)# timeout 120s
sales-prouter-01(config-block)# exit
sales-prouter-01(config-process)# commit
Commit complete.
```

It feels like configuring a network router; underneath, it's a real
scheduler with persistent commit history, conditional routing, retries,
replay, webhooks, and cron — all behind one CLI. Outbound interfaces
(docker, shell, http) call out to the world; inbound interfaces
(webhook, cron, manual) trigger runs. Blocks reference an outbound
interface by full name and supply per-call args (`command`, `body`,
…), templated against runtime context with `{{...}}`.

## Quick start

### Option A — Docker (no Ruby on the host)

```bash
docker build -t prouterd:latest .
docker run --rm -p 127.0.0.1:8080:8080 \
  -v prouterd-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e PROUTERD_ADMIN_TOKEN=demo \
  prouterd:latest
```

That gets you the HTTP daemon + cron scheduler + worker pool on
`127.0.0.1:8080` of the host (loopback only — for multi-host access
put a TLS reverse proxy in front and change `127.0.0.1:8080:8080` to
`8080:8080`). From another shell:

```bash
curl -s http://127.0.0.1:8080/v1/status

# One-shot CLI inside the running container:
docker exec <container> bundle exec ruby exe/prouter exec "show running-config"
```

The `/var/run/docker.sock` mount is what lets `interface docker`
blocks spawn child containers on the host's Docker daemon. If your
pipelines are pure `interface shell` (host processes), you can drop
the socket mount entirely — prouterd has no hard dependency on
Docker. There's also a `docker-compose.yml` in the repo for a
persistent setup.

### Option B — local Ruby

Requires Ruby ≥ 3.2 and `libsqlite3-dev`. The base install is
deliberately small — only `interface shell` (host processes), `interface
http`, and `interface llm` work out of the box (the latter two ride on
Ruby's stdlib `Net::HTTP`). Heavier outbound interfaces are opt-in:

| Feature                           | Install                |
| --------------------------------- | ---------------------- |
| `interface docker` (containers)   | `gem install docker-api` |
| `interface postgres` (SQL)        | `gem install pg`       |
| `interface cron` (cron schedules) | `gem install fugit`    |

If a config references a feature whose gem isn't installed, the run
fails with `error_type: "missing_dependency"` and a one-line message
telling you which gem to install — no `LoadError` at parse time, no
crashed daemon. Cron interfaces simply don't fire and the scheduler
logs a single warning.

```bash
git clone <this-repo>
cd prouterd
bundle install

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
executables, durable run history, and a CLI you can drive from scripts
and tail in tmux.

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

Business logic lives **inside blocks** — the config doesn't care
whether a block is a Docker container, a host-side shell process, or
a future Lambda/k8s plugin. It just routes events to them.

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

prouter version | help
```

The long-running daemon is a separate binary, `prouterd`:

```
prouterd [--bind ADDR] [--port N] [--workers N] [--db PATH] [--runner KIND]
                                         HTTP daemon: webhooks + cron + /v1 API
prouterd --version | --help
```

### HTTP daemon endpoints

`prouterd` exposes:

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
- `--config FILE` load this `.prc` file as the running config
- `--runner KIND` `docker` (default) or `stub` (env `PROUTERD_RUNNER`)
- `--no-db`       in-memory mode for read-only commands only
                  (`check` / `render` / `shell` / `exec`); the daemon
                  and any command that mutates state (`apply`, `trigger`,
                  `serve`, `replay`, `cancel`, `cleanup`) requires `--db`

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

bundle exec ruby exe/prouterd \
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

interface docker extractor
 image registry.local/blocks/extract:v1
exit

interface docker scorer
 image registry.local/blocks/score:v2
exit

interface docker notifier
 image registry.local/blocks/notify-sales:v1
exit

interface shell normalizer
 cwd ./blocks/normalize
exit

process lead_pipeline
 description "Lead enrichment + sales notification"
 queue default
 no shutdown

 block extract
  interface docker extractor
  timeout 30s
  enable
 exit

 block normalize
  interface shell normalizer
  exec "ruby app.rb"
  timeout 20s
  enable
 exit

 block score
  interface docker scorer
  timeout 20s
  retry retry_standard
  enable
 exit

 block notify_sales
  interface docker notifier
  timeout 15s
  secret WEBHOOK_TOKEN
  enable
 exit

 ! short-form route (no conditions)
 route extract normalize
 route normalize score

 ! long-form route with match conditions, referencing the upstream
 ! block's output by `<block-name>.<field>`
 route score notify_sales
  match score.value gt 70
 exit
exit

route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
```

### Outbound interfaces (built-in)

Outbound interfaces are how blocks call out to the world. The plugin
declares a `field` schema for the interface body (image, exec, base
URL, …) and a `call_field` schema for the per-block-call body
(command, query, body, …). The block references the interface by full
name and overrides only what it needs:

- `interface shell <name>` — runs the block as a host process via
  `Open3`. **Default install** (no extra gem). Interface fields:
  `cwd`, `shell`, `env KEY VALUE`. Per-call fields: `exec` (required).
  Lower latency, blocks see the daemon's filesystem. Stdout that
  parses as JSON becomes `output_json` automatically (no need to
  redirect to `/prouter/output.json` in trivial cases).
- `interface http <name>` — POSTs/GETs to a remote endpoint via
  `Net::HTTP`. Default install. Interface fields: `base-url`,
  `auth bearer secret …`. Per-call fields: `method`, `path`, `query`,
  `body-json`. Hits Jira, GitHub, any JSON HTTP API as a step.
- `interface llm <name>` — chat-completion call to Anthropic or
  OpenAI via `Net::HTTP`. Default install. Interface fields:
  `provider` (`anthropic` | `openai`), `model`, `auth bearer secret
  …`, `base-url` (optional). Per-call fields: `prompt` (required),
  `system`, `max-tokens`, `temperature`. Output is a normalized
  `{text, model, usage, stop_reason}` Hash.
- `interface docker <name>` — runs the block as a Docker container.
  Requires `gem install docker-api`. Interface fields: `image`
  (required), `pull`, `network`, `user`, `memory`, `cpu`. Per-call
  fields: `command`. Best for: multi-language pipelines, audit-grade
  reproducibility (config pins an image digest), strong isolation.
- `interface postgres <name>` — SQL via `pg`. Requires
  `gem install pg`. Interface fields: `dsn` (required, templatable
  with `{{secret.PG_DSN}}`), `statement-timeout`. Per-call fields:
  `query` (required), `params` (comma-separated, bound to `$1..$N`).
  Output: `{rows, row_count, fields}`.

All five honour the same `/prouter/{input.json,output.json,artifacts/,inputs/}`
contract. A single pipeline can mix types freely — `shell` for a fast
preprocessor, `http` for the external Jira call, `postgres` for the
warehouse lookup, `llm` for the summarization, `docker` for the heavy
CUDA step.

#### Choosing between docker and shell

| Concern                                        | `shell` | `docker` |
|------------------------------------------------|:-------:|:--------:|
| Block uses curl / jq / sh / Ruby script        | ✓       | overkill |
| Multiple blocks, different language runtimes   | painful | ✓        |
| Audit / reproducibility via image digest       | —       | ✓        |
| Block needs to run untrusted code              | —       | ✓        |
| Resource limits (memory / CPU caps)            | —       | ✓        |
| Single-host, no registry, low latency          | ✓       | overhead |
| Edge / IoT (no Docker daemon)                  | ✓       | —        |

**Adding your own interface type** is a single plugin file + a single
caller class — parser/validator/renderer/show/CLI all discover the
type via `Iface::Registry`, so the core has zero hardcoded type names.
See the "Adding a new interface type" section in
[CLAUDE.md](CLAUDE.md#adding-a-new-interface-type) for the worked
recipe.

### Match operators

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `exists`, `in`. Multiple matches
within one route AND together. There is no OR — use a separate route.

### Block contract (docker / shell)

The docker and shell runners both expose a per-step working directory
at `/prouter`:

| Path                         | Direction | Purpose                                                |
|------------------------------|-----------|--------------------------------------------------------|
| `/prouter/input.json`        | read      | run_id, process, block, full context                   |
| `/prouter/output.json`       | write     | block's JSON result                                    |
| `/prouter/artifacts/`        | write     | files to archive (consumable by downstream blocks)     |
| `/prouter/inputs/<name>`     | read      | staged artifact from upstream `produces` declarations  |

Environment variables: `PROUTER_RUN_ID`, `PROUTER_PROCESS_NAME`,
`PROUTER_BLOCK_NAME`, `PROUTER_ATTEMPT`, `PROUTER_INPUT_PATH`,
`PROUTER_OUTPUT_PATH`, `PROUTER_ARTIFACTS_DIR`, plus
`PROUTER_INPUT_<NAME>` for each staged artifact and every secret
declared on the block.

Output rules:

- **docker**: strict — `exit_code == 0` AND `output.json` exists AND
  parses as valid JSON AND every `produces <relpath>` was written.
  The container's filesystem IS the contract surface.
- **shell**: lenient — `exit_code == 0` is enough. If `output.json`
  doesn't exist, the runner trims stdout and parses it as JSON; if
  that yields a Hash or Array, it becomes `output_json`. Pure log
  text falls through to `{}`. The block can still write the file
  explicitly to override.

For HTTP / LLM / Postgres callers there is no filesystem; output
shape is plugin-specific (see "Outbound interfaces" above).

### Two ways data flows between blocks

| Use for                                | Declare with                                | Reaches the block via               |
|----------------------------------------|---------------------------------------------|-------------------------------------|
| JSON values (fields, numbers, …)       | `{{<upstream-block>.<field>}}` in call-args | templated call-fields + `/prouter/input.json` (`context` key) |
| Files (model.pkl, parquet, CSV, blobs) | `produces <relpath>` / `input from <b>.<r>` | `/prouter/inputs/<derived_name>`    |

Each block's `output.json` is auto-stored at `context[block.name]`, so
downstream blocks can reference it from call-fields with
`{{<block-name>.<field>}}` (templated by `Util::Templater` right before
dispatch) or read the full context from `/prouter/input.json`. There's
no `input` / `output` directive on blocks — outputs are auto-keyed,
inputs flow via templating.

Both mechanisms can coexist on the same block. See
[examples/08_typed_artifacts.prc](examples/08_typed_artifacts.prc).

## Architecture

```
lib/prouterd/
  config/         lexer, parser, AST, validator, renderer
  shell/          mode stack (>, #, config, config-process, config-block)
  storage/        SQLite + migrations + repositories
  control_plane/  ConfigStore (commit/rollback/write_memory)
  iface/          Plugin/Registry, plugins/{webhook,cron,manual,
                  docker,shell,http,llm,postgres}.rb, callers
                  (HttpCaller, LlmCaller, PostgresCaller)
  runner/         CallRunner (dispatches to caller via Iface::Registry),
                  StubRunner, RunRequest/ExecutionResult value types
  runtime/        Orchestrator, Context, MatchEvaluator, ContractValidator,
                  RetryCalculator, Redactor, Recovery, Tracer, Scheduler,
                  WorkerPool, InFlightRegistry
  util/           Templater (lightweight {{path}} substitution)
  api/            Rack app + WebhookHandler + Puma launcher
  cli/main.rb     prouter binary
  daemon.rb       prouterd daemon entry point (exe/prouterd)
  bootstrap.rb    shared CLI/daemon helpers (open_store, build_runner)
exe/prouter       operator CLI binary (one-shot subcommands)
exe/prouterd      long-running daemon binary (HTTP + cron + workers)
```

Storage schema (SQLite, WAL):

- `config_commits` + `config_pointers` (running, startup)
- `runs`, `run_steps`, `run_logs`, `artifacts`
- `schema_migrations`

## Running tests

```bash
bundle exec rspec
```

617 specs cover lexer / parser / validator / renderer (incl. backtick
raw strings), shell flows + router-style prefix abbreviation, tab
completion, storage repositories, ConfigStore lifecycle, orchestrator
with stub runner, match evaluator, contract validation, retry / replay /
cancel / diff / scheduler, webhook handler, IPC events bus + WebSocket
endpoints, iface plugin registration end-to-end on a fake outbound
plugin, the http / llm / postgres callers (unit + orchestrator-level
integration), retry-when + `{{previous}}` / `{{iteration}}` overlay
templating, missing-dep paths for docker-api / pg / fugit, the
structured logger, body-size enforcement, secret resolvers (env + file),
rate-limiter eviction, log-capture cap, and a full
apply → trigger → replay → rollback integration test.

The Docker-dependent paths are tested with a `StubRunner`. To exercise
real Docker, the `examples/` scripts run pipelines against
`alpine:latest` end-to-end.

## Status

Production-ready core: config language with `{{path}}` templating and
backtick raw strings, persistent commit history, runtime with parallel
DAG execution, smart retries (`retry when` + `{{previous}}` /
`{{iteration}}`), replay, three inbound interfaces
(webhook / cron / manual), five outbound interfaces
(shell / docker / http / llm / postgres) — all extensible via
`Iface::Plugin`, /v1 HTTP API, /metrics, graceful shutdown, output
contracts, typed artifacts. See [CHANGELOG.md](CHANGELOG.md) for the
full per-version breakdown.

A web console (object tree, run inspector, embedded CLI, live updates
over WebSocket) ships as a separate gem, **prouterd-web**, which
connects to the daemon's `/v1` HTTP + `/v1/events` WS — no shared gem
or DB.

Deliberately out of v0.1 scope (workable without these for now):

- ☐ KubernetesCaller / LambdaCaller / ... (the iface plugin interface
  is ready — write a plugin file and a caller class, no core edits)
- ☐ S3 / object-store artifacts (`ArtifactStore` interface ready)
- ☐ Vault / AWS Secrets Manager (write a class with `#resolve(secret)`,
  inject via `secret_resolver:` — env + file are built-in)
- ☐ RBAC / mTLS / OIDC (basic admin bearer is in; HTTPS is on)
- ☐ Postgres as the daemon's own storage backend (`Storage::DB`
  abstraction is ready; only the SQLite implementation exists — this
  is unrelated to `interface postgres`, which lets blocks query an
  external Postgres database)
- ☐ Idempotency keys
