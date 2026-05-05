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
| `PROUTERD_CONTAINER_STOP_TIMEOUT`  | `10` (s)             | SIGTERM grace before SIGKILL on cancel           |
| `PROUTERD_JOB_LOCK_TIMEOUT`        | `60` (s)             | Recovery: re-queue job locks older than this     |
| `PROUTERD_WEBHOOK_RATE`            | `60/1`               | `MAX/WINDOW` per-interface webhook rate limit    |
| `PROUTERD_ARTIFACTS_ROOT`          | `var/artifacts`      | Where `ArtifactStore` writes block outputs       |
| `PROUTERD_DB`                      | `var/prouterd.db`    | SQLite path                                      |

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

## Cleanup

A long-running cleanup splits into N-row transactions so the table
isn't write-locked for minutes on a million-run sweep.

```bash
prouter cleanup --older-than 90d --batch-size 500 \
  --db /var/lib/prouterd/prouterd.db
```

`--dry-run` reports what would be deleted without touching anything.

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
