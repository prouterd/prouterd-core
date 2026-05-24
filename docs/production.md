# Production deployment

## Environment variables

Everything operationally tunable comes from the environment so secrets
and limits don't end up in `.prc` files or `ps` output.

| Var                                | Default              | Effect                                           |
| ---------------------------------- | -------------------- | ------------------------------------------------ |
| `PROUTERD_ADMIN_TOKEN`             | _(unset → open)_     | Bearer token for `/v1/*`                         |
| `PROUTERD_LOG_LEVEL`               | `info`               | `debug` / `info` / `warn` / `error` / `fatal`    |
| `PROUTERD_SSL_CERT` + `..._KEY`    | _(plain HTTP)_       | PEM cert + key paths for HTTPS                   |
| `PROUTERD_MAX_BODY_BYTES`          | `1048576` (1 MB)     | Reject `/i/*` and most `/v1` POSTs above this    |
| `PROUTERD_MAX_CONFIG_BYTES`        | `4194304` (4 MB)     | Higher cap for `/v1/config/{check,apply}`        |
| `PROUTERD_LOG_CAPTURE_BYTES`       | `1048576` (1 MB)     | Per-stream cap on persisted container logs       |
| `PROUTERD_MAX_OUTPUT_BYTES`        | `4194304` (4 MB)     | Cap on a block's explicit `output.json`          |
| `PROUTERD_CONTAINER_STOP_TIMEOUT`  | `10` (s)             | SIGTERM grace before SIGKILL on cancel           |
| `PROUTERD_RUN_DEFAULT_TIMEOUT_MS`  | `21600000` (6 h)     | Wall-clock cap when no process/queue timeout set; over-cap kills in-flight containers and finalizes the run with `error_type: "run_timeout"` |
| `PROUTERD_JOB_LOCK_TIMEOUT`        | `60` (s)             | Recovery: re-queue job locks older than this     |
| `PROUTERD_STORAGE_PROBE_SECONDS`   | `30` (s)             | Background probe interval. On `db.healthy?` flip, daemon toggles between accepting writes and returning 503 |
| `PROUTERD_WEBHOOK_RATE`            | `60/1`               | `MAX/WINDOW` per-interface webhook rate limit    |
| `PROUTERD_ARTIFACTS_ROOT`          | `var/artifacts`      | Where `ArtifactStore` writes block outputs       |
| `PROUTERD_DB`                      | `var/prouterd.db`    | SQLite path                                      |
| `PROUTERD_RUNNER`                  | `docker`             | Default runner kind: `docker` / `shell` / `stub`. Overridable per-invocation with `--runner` |

## Hardened invocation

HTTPS, secrets read from disk (Docker Compose / Kubernetes /
systemd-LoadCredential all expose the same shape), capped log capture,
generous container-stop window so blocks can flush `output.json` before
SIGKILL.

```bash
export PROUTERD_ADMIN_TOKEN="$(cat /run/secrets/prouterd_admin)"
export PROUTERD_SSL_CERT=/etc/prouterd/tls/cert.pem
export PROUTERD_SSL_KEY=/etc/prouterd/tls/key.pem
export PROUTERD_LOG_LEVEL=info
export PROUTERD_LOG_CAPTURE_BYTES=4194304       # 4 MB per stream
export PROUTERD_CONTAINER_STOP_TIMEOUT=30       # 30s graceful SIGTERM
export PROUTERD_ARTIFACTS_ROOT=/var/lib/prouterd/artifacts

prouterd \
  --bind 0.0.0.0 --port 8443 \
  --db /var/lib/prouterd/prouterd.db \
  --workers 8
```

## Secrets

For tokens / API keys that the daemon must inject into blocks at run
time, declare them in the DSL and point at either an env var or a file
the daemon can read:

```prc
secret API_TOKEN
 source file /run/secrets/api_token   ! Docker secret / k8s secret volume
exit
```

Resolved values reach the block as an env var (for shell / docker) or
as the auth header value (for http / llm). Rendered config never
contains the secret value — only the source pointer. All log streams
go through `Redactor`, which scrubs every declared secret value.

## Subprocess LLM spawn isolation

`interface llm` with `provider codex_cli` / `provider claude_cli`
spawns a local CLI binary. By default the spawn inherits the daemon's
full environment (Open3.popen3 merges the env hash on top of the
parent process env). Declare any of `env` / `env-forward` / `secret`
on the interface to flip the spawn into strict mode
(`unsetenv_others: true`); the subprocess then sees only:

  1. HOME (the iface's `home`, else the daemon's HOME)
  2. each `env KEY VALUE` (templated against the run context)
  3. each `env-forward KEY` (passed through only if set on the daemon)
  4. each `secret <NAME>` (resolved at spawn time)

Strict mode is the recommended posture whenever the prompt or any
templated call-field could contain attacker-controlled text — without
it, a prompt-injection in the input event can ask the agent to read
arbitrary daemon env vars and exfiltrate them via tool calls or
plain stdout. Note that strict mode also drops `PATH`; if the agent
needs to fork sub-commands, add `env-forward PATH` explicitly.

```prc
interface llm researcher
 provider codex_cli
 model gpt-5-codex
 home /var/lib/prouterd/codex
 env-forward PATH                ! the agent shells out to git
 env-forward HTTPS_PROXY         ! corp egress
 secret SENTRY_AUTH              ! resolved → env SENTRY_AUTH=<value>
exit
```

## Retention

Run retention is driven externally — host cron + a small Ruby script
that calls the library directly. The convenience `prouter cleanup` CLI
was removed in Phase 40; the module behind it (`ControlPlane::Cleanup`)
stayed and is the supported entry point.

```ruby
# /usr/local/bin/prouterd-cleanup.rb
require "prouterd"

db = Prouterd::Storage::DB.open("/var/lib/prouterd/prouterd.db")
result = Prouterd::ControlPlane::Cleanup.sweep(
  db,
  older_than: 90 * 24 * 3600,   # seconds
  dry_run:    false,
  batch_size: 500,
)
puts "deleted runs=#{result.runs} steps=#{result.steps} logs=#{result.logs} artifacts=#{result.artifacts}"
```

```cron
# /etc/cron.d/prouterd
17 4 * * * prouterd /usr/local/bin/prouterd-cleanup.rb >> /var/log/prouterd-cleanup.log 2>&1
```

Only runs in terminal status (`success` / `failed` / `canceled` /
`timeout`) are eligible. Config commits are never pruned — the audit
trail is intentional. Pass `dry_run: true` to preview without touching
the DB. Batching keeps each transaction short so concurrent writes are
not blocked for long.

## Crash recovery

On daemon boot, the recovery sweep:

1. Marks every `running` / `queued` run with no live worker as
   `failed` with `error_type: "recovered"`.
2. Re-queues durable jobs whose lock is older than
   `PROUTERD_JOB_LOCK_TIMEOUT`.

In-flight Docker containers attached to a recovered run are stopped on
the next `cancel`. Cron's `@last_fired` is in-memory — misses during
downtime are silently dropped (no catch-up).

## Observability

- `/metrics` — Prometheus text format. Counters per process / status,
  uptime, in-flight gauge.
- `/v1/events` — WebSocket. Live `step_created` / `step_updated` /
  `log_appended` / `run_finished` events.
- Structured logs to stdout: `<ts> <LEVEL> prouterd: <message> k=v k=v…`
  — single-line, grep-able, no JSON unless a value contains spaces.
