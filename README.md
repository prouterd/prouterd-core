# prouterd

**Configure event pipelines like a network router. Run them like Kubernetes jobs.**

A single binary that listens for webhooks, fires on cron, and threads
events through declarative pipelines that call out to shell, HTTP, LLM,
SQL, and Docker. Config lives in a router-style DSL you can read,
diff, and version. Operators drive it through an interactive shell
that already feels familiar if you've ever typed `configure terminal`.

```text
$ prouter trigger process triage input ticket.json --runner shell
Run run_a3f2: success (4.2s)
  fetch_ticket    success  890ms   GET /issue/PROJ-123          → 200
  recent_history  success  120ms   SELECT … LIMIT 20            → 18 rows
  summarize       success  3100ms  claude-haiku-4.5             → 287 tokens
  post_comment    success  140ms   POST /issue/PROJ-123/comment → 201

$ wc -l examples/12_jira_debug/jira_debug.prc
40 examples/12_jira_debug/jira_debug.prc
```

The pipeline above: GitHub-style webhook → Jira REST → Postgres
warehouse lookup → Claude summary → Jira comment. **40 lines of DSL,
no glue code.** See [examples/12_jira_debug](examples/12_jira_debug/).

## Why prouterd

| If you're choosing between prouterd and… | What's different                                    |
| ---------------------------------------- | --------------------------------------------------- |
| **n8n** / **Zapier** / **Make**          | config in git, not a hosted UI database. Diff. PR. Roll back. |
| **Airflow** / **Argo Workflows**         | one binary, one SQLite file. No k8s, no scheduler DB. |
| **GitHub Actions**                       | runs as a daemon. Webhooks land in milliseconds.    |
| **Temporal** / **Cadence**               | declarative DSL instead of code. Operator shell.    |
| **Step Functions** / **Workflows**       | self-hosted, single binary. No vendor lock.         |
| **shell scripts in a tmux session**      | retries, replay, rate limits, audit log, structured run history. |

It's the orchestrator a senior platform engineer would write for
themselves on a Friday afternoon — except it's already written.

## 30-second demo

```bash
gem install prouterd
echo '{"name":"world"}' > /tmp/event.json

cat > /tmp/hello.prc <<'EOF'
router demo
exit
interface manual cli
 no shutdown
exit
interface shell host
exit
process hello
 block greet
  interface shell host
  exec "echo hello, {{event.name}}!"
 exit
exit
route interface cli process hello
exit
EOF

prouter apply   /tmp/hello.prc                  --db /tmp/p.db
prouter trigger process hello input /tmp/event.json --db /tmp/p.db --runner shell
# → Run run_xxx: success
#     greet  success  3ms     [stdout: hello, world!]
```

That's the whole loop: declare → apply → trigger → inspect. The same
flow works in a long-running daemon (`prouterd`) where the trigger
arrives via webhook or cron instead of a CLI command.

## What blocks can do (built-in interfaces)

The base install runs on Ruby stdlib — no Docker daemon required.
Heavier callers are explicit `gem install` away.

| `interface …`       | Does what                                        | Needs                     |
| ------------------- | ------------------------------------------------ | ------------------------- |
| `shell <name>`      | Host process via `Open3`                         | _(default)_               |
| `http <name>`       | `Net::HTTP` GET/POST/… JSON APIs                 | _(default)_               |
| `llm <name>`        | Anthropic / OpenAI chat completion               | _(default)_               |
| `webhook <name>`    | Inbound HTTPS endpoint with bearer auth          | _(default)_               |
| `manual <name>`     | Inbound entry for `prouter trigger`              | _(default)_               |
| `docker <name>`     | OCI container, `image:tag` pinned, with limits   | `gem install docker-api`  |
| `postgres <name>`   | SQL with `$1..$N` bind params                    | `gem install pg`          |
| `cron <name>`       | Inbound cron schedule                            | `gem install fugit`       |

Adding your own interface type is one plugin file + one caller class —
no edits to parser/validator/renderer/CLI. See
[CLAUDE.md](CLAUDE.md#adding-a-new-interface-type) for the worked
recipe.

## How a pipeline is shaped

```
inbound (webhook / cron / manual)
        │
        ▼
   global route ── matches event ─┐
                                  │
                                  ▼
                            process foo
                                  │
                          ┌───────┼───────┐
                          ▼       ▼       ▼
                       block   block   block         ── parallel level
                          │       │       │             (if same DAG depth)
                          └───────┼───────┘
                                  ▼
                                next level
                                  │
                                  ▼
                          {{block.field}} flows
                          to downstream call-fields
```

Each block calls one outbound interface (shell, http, llm, docker,
postgres). Block output auto-stores at `context[block.name]`. Downstream
blocks read it via `{{block.field}}` templating. No `input` / `output`
directives — config stays declarative.

## What you get with it

- **Persistent commit history** — every `apply` is a versioned commit.
  `show config commits`. `rollback`. `diff file running-config`.
- **Smart retries** — `retry attempts 3 backoff exponential` and
  `retry when error_type in "timeout","http_status"`. The retry
  attempt sees `{{previous.error_type}}` and `{{iteration}}` for
  retry-with-feedback patterns.
- **Replay** — re-run a finished run with the same input + same
  config commit (even if the running config has changed since), or
  start mid-pipeline from a chosen block.
- **Cancel** — soft (between-level halt) or hard (SIGTERM the live
  container).
- **Output contracts** — declare expected JSON shape, validate at
  runtime, fail / retry / warn on violation.
- **Typed artifacts** — `produces model.pkl`, `input from train.model.pkl`.
  Files between blocks, not just JSON.
- **Webhook ingestion** — `interface webhook leads_in` with bearer
  auth, rate limits, body-size cap, async dispatch.
- **Cron** — fugit syntax, `Europe/Berlin`-style timezones.
- **/metrics** Prometheus, **/v1/events** WebSocket live tail.
- **Graceful shutdown** — drains in-flight runs before stopping.

## Install

```bash
gem install prouterd
```

Requires Ruby ≥ 3.2. SQLite is the only hard runtime dependency
(plus rack + puma for the daemon). For Docker / Postgres / cron
features see the table above.

Or run as a container:

```bash
docker run --rm -p 127.0.0.1:8080:8080 \
  -v prouterd-data:/data \
  -e PROUTERD_ADMIN_TOKEN=demo \
  ghcr.io/prouterd/prouterd:latest
```

## Documentation

- [`docs/dsl.md`](docs/dsl.md) — full `.prc` reference
- [`docs/cli.md`](docs/cli.md) — `prouter` + `prouterd` commands, HTTP endpoints
- [`docs/production.md`](docs/production.md) — env vars, secrets, deployment
- [`CLAUDE.md`](CLAUDE.md) — internals + extension recipes
- [`examples/`](examples/) — twelve runnable `.prc` files, including
  end-to-end pipelines:
  - [01_hello_world](examples/01_hello_world.prc) — minimal shell
  - [02_conditional_routing](examples/02_conditional_routing.prc) — `match` on routes
  - [11_retry_when](examples/11_retry_when.prc) — smart retries
  - [10_tg_github](examples/10_tg_github/) — GitHub → Telegram
  - [12_jira_debug](examples/12_jira_debug/) — webhook → http → postgres → llm → http

## Status

Production-ready core. 627 specs, 0 failures. End-to-end smoked
against real Docker, Puma, cron, and shell exec. Deliberately out of
scope for v0.1: KubernetesCaller, S3 ArtifactStore, Vault / AWS
Secrets Manager, RBAC / mTLS / OIDC, idempotency keys. The plugin
interfaces are ready — write a plugin file and a caller class, no
core edits.

A web console (object tree, run inspector, embedded CLI, live updates
over WebSocket) ships as a separate gem, **prouterd-web**, talking
to the daemon over `/v1` HTTP + `/v1/events` WS.

See [CHANGELOG.md](CHANGELOG.md) for the per-version breakdown
(31 phases shipped).

## License

MIT.
