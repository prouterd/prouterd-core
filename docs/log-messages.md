# Daemon log catalog

prouterd writes syslog-style log lines to stdout and to an in-memory
ring buffer that the shell's `show logging` command reads:

    May  8 14:23:01.234: %DAEMON-6-STARTING: daemon starting bind=127.0.0.1 port=8080

The triplet `%FACILITY-SEVERITY-MNEMONIC` is the operator's grep key.
This file documents every mnemonic that the daemon currently emits —
severity, format, what it means, and what (if anything) you should do
about it.

## Severity scale

prouterd uses the standard syslog 0–7 scale:

| # | Name          | Meaning                                                  |
|---|---------------|----------------------------------------------------------|
| 0 | emergency     | system is unusable (not currently emitted)               |
| 1 | alert         | immediate action required (not currently emitted)        |
| 2 | critical      | critical conditions (not currently emitted)              |
| 3 | error         | error condition — something failed                       |
| 4 | warning       | a problem you should look at, daemon kept going          |
| 5 | notice        | normal but significant — config / lifecycle              |
| 6 | informational | normal operation                                          |
| 7 | debug         | debug detail (only with `PROUTERD_LOG_LEVEL=debug`)      |

## Filtering

    show logging                                  # configuration summary
    show logging last 50                          # last 50 entries
    show logging last 200 severity 4              # only warnings + errors
    show logging last 100 facility RUN            # only run-lifecycle
    show logging last 100 facility WEBHOOK severity 4

`severity N` keeps entries at level ≤ N (so `severity 4` shows
warnings, errors, and worse).

The ring buffer is process-local (the running `prouterd`) and bounded
to 1000 entries. For durable audit, capture stdout via
journald / `docker logs` / a Kubernetes sidecar — the same line goes
to both the ring and stdout.

## Catalog

### DAEMON — process lifecycle

#### %DAEMON-6-STARTING

Severity 6 (informational). Format:

    daemon starting bind=<addr> port=<n> db=<path> workers=<n> runner=<kind>

Emitted exactly once when `prouterd` boots after argument parsing and
storage open. Carries the bind/port/workers used so an operator can
confirm config flags took effect.

Action: none — informational.

#### %DAEMON-4-OPEN_AUTH

Severity 4 (warning). Format:

    PROUTERD_ADMIN_TOKEN not set; /v1/* endpoints are open

`PROUTERD_ADMIN_TOKEN` was empty or unset at boot. The `/v1/*` admin
endpoints will accept unauthenticated requests.

Action: set `PROUTERD_ADMIN_TOKEN` (or front the daemon with a reverse
proxy enforcing auth) before exposing the port.

#### %DAEMON-6-LISTENING

Severity 6. Format:

    HTTP listening bind=<addr> port=<n>
    HTTPS listening bind=<addr> port=<n> cert=<path>

Server bound and ready to accept requests.

#### %DAEMON-6-LISTENER_STOP

Severity 6. Format: `listener stopped`

Puma has stopped accepting new requests. Always followed by drain.

#### %DAEMON-6-SHUTDOWN_SIGNAL

Severity 6. Format: `shutdown signal received signal=<NAME>`

SIGINT / SIGTERM received. Daemon begins graceful drain.

#### %DAEMON-6-DRAINING

Severity 6. Format: `draining in-flight runs in_flight=<n>`

Waiting for `n` runs to finish before exiting.

#### %DAEMON-4-DRAIN_TIMEOUT

Severity 4. Format: `drain timed out in_flight=<n> seconds=<n>`

Drain did not finish before `PROUTERD_DRAIN_SECONDS`. Daemon exits
anyway; orphaned runs will be swept on the next boot (see
`%RECOV-5-SWEPT`).

#### %DAEMON-6-STOPPED

Severity 6. Format: `daemon stopped`

Daemon exited cleanly.

### STORE — SQLite / disk health

#### %STORE-3-UNAVAILABLE

Severity 3 (error). Format:

    storage unavailable error=<class> message=<...>

A write probe (or a real query) failed with `ENOSPC` /
`SQLite3::IOException` / `SQLite3::FullException`. Daemon flips
`accepting` off — webhooks and `/v1/*` write endpoints return 503.

Action: free disk on the volume holding `--db`. The daemon will
recover automatically (see `%STORE-5-RECOVERED`).

#### %STORE-3-FAILING

Severity 3. Format:

    storage probe failed; pausing intake error=<class> message=<...>

Same condition as `UNAVAILABLE` but raised from the periodic prober
(`PROUTERD_STORAGE_PROBE_SECONDS`, default 30s).

#### %STORE-5-RECOVERED

Severity 5 (notice). Format: `storage writes recovered; intake resumed`

A previously-failing storage probe succeeded. The daemon resumes
accepting webhooks and `/v1/*` writes.

#### %STORE-4-PROBE_ERR

Severity 4 (warning). Format:

    storage prober crashed error=<class> message=<...>

The probe thread itself raised an unexpected exception (not the disk
errors that get classified above). Daemon keeps running, intake stays
in whatever state it was.

### CONFIG — config-store lifecycle

#### %CONFIG-5-APPLIED

Severity 5. Format:

    running config applied commit_id=<n> author=<...> message=<...> bytes=<n>

A new commit was saved and the `running` pointer moved to it. Source:
shell `commit`, `apply <file>`, or `POST /v1/config` from the web/API.

#### %CONFIG-5-SAVED

Severity 5. Format: `startup config saved commit_id=<n>`

`write memory` / `copy running-config startup-config` blessed the
running commit as the boot configuration.

#### %CONFIG-5-ROLLBACK

Severity 5. Format: `running config rolled back commit_id=<n>`

`rollback commit <id>` moved the running pointer to an earlier commit.

### SECRET — secret resolution

#### %SECRET-3-MISSING (HMAC path)

Severity 3. Format:

    hmac-sha256 secret unresolved interface=<name> secret=<name>

A webhook with `hmac-sha256` set could not resolve the named secret —
the env var was unset or the file was missing. The webhook returns
HTTP 500.

Action: set the referenced env var (or check the secret file path).

#### %SECRET-4-MISSING (block env path)

Severity 4. Format:

    secret resolved to empty value secret=<name> source=<env|file> block=<name> run_uid=<uid>

A block declares `secret X` but the resolved value is empty. The block
still runs (the empty value is forwarded to the container as an empty
string), but the container will likely fail a downstream auth call.

Action: set the env var or restore the secret file before running
again. Consider replaying the run (`prouter replay <uid>`) once the
secret is in place.

### RUN — orchestrator run lifecycle

#### %RUN-6-COMPLETED

Severity 6. Format:

    run success run_uid=<uid> process=<name> duration_ms=<n> error=-

A run finished with `status=success`.

#### %RUN-3-FAILED

Severity 3. Format:

    run failed run_uid=<uid> process=<name> duration_ms=<n> error=<...>

A run finished with `status=failed`. The `error` field carries the
short summary; `prouter show run <uid>` has the full timeline.

Action: investigate the failing block (`prouter show logs run <uid>`).
Common causes: contract violation, retry exhaustion, container OOM,
upstream API 5xx.

#### %RUN-6-CANCELED

Severity 6. Format:

    run canceled run_uid=<uid> process=<name> duration_ms=<n> error=<...>

`prouter cancel <uid>` (or `POST /v1/runs/:uid/cancel`) terminated the
run.

#### %RUN-5-PAUSED

Severity 5. Format:

    run paused run_uid=<uid> process=<name> block=<name>

A `pause` block stopped the run waiting for an external resume.

#### %RUN-5-RESUMED

Severity 5. Format:

    run resumed run_uid=<uid> process=<name> block=<name>

`prouter resume run <uid>` (or the by-thread variant) signaled a
paused run to continue.

### WEBHOOK — inbound HTTP

#### %WEBHOOK-6-ACCEPTED

Severity 6. Format:

    webhook accepted interface=<name> process=<name> run_uid=<uid>

A webhook request passed auth/HMAC, matched a global route, and was
enqueued.

#### %WEBHOOK-4-HMAC_FAIL

Severity 4. Format:

    hmac signature mismatch interface=<name> header=<header-name>

A request to a webhook with `hmac-sha256` carried a header whose
digest did not match the configured secret. Returns HTTP 401. Repeated
mismatches usually mean the wrong secret on either side.

Action: confirm the upstream signs with the same secret bytes prouterd
resolves. For Slack: Signing Secret. For GitHub: Webhook secret.

### WORK — worker pool

#### %WORK-6-STARTING

Severity 6. Format: `worker-pool starting workers=<n>`

The worker pool spawned its threads.

#### %WORK-3-CLAIM_ERR

Severity 3. Format:

    claim error worker=<id> error=<class> message=<...>

A worker hit an unexpected exception while claiming a job. The worker
loops back and tries again after the poll interval. Persistent errors
here usually indicate DB-level corruption.

#### %WORK-3-RUN_CRASHED

Severity 3. Format:

    run crashed worker=<id> run_id=<n> error=<class> message=<...>

A worker caught an exception escaping `Orchestrator#execute_run`. The
run is finalized as failed and the job is marked failed.

### SCHED — cron scheduler + git auto-pull

#### %SCHED-6-CRON_FIRED

Severity 6. Format:

    cron fired interface=<name> process=<name> schedule=<expr>

A cron interface tick matched and a run was enqueued.

#### %SCHED-4-CRON_INVALID

Severity 4. Format:

    cron schedule invalid interface=<name> schedule=<expr> error=<...>

`fugit` could not parse the schedule. The interface is skipped each
tick until reconfigured.

Action: fix the cron expression (validate with `fugit-cron <expr>`).

#### %SCHED-4-CRON_UNROUTED

Severity 4. Format:

    cron interface unrouted interface=<name>

The cron tick fired but no global route maps the interface to a
process. The tick is dropped.

#### %SCHED-4-CRON_UNKNOWN_PROC

Severity 4. Format:

    cron route targets unknown process interface=<name> process=<name>

A cron route names a process that no longer exists in the running
config. Tick dropped.

#### %SCHED-4-FUGIT_MISSING

Severity 4. Format: `cron support disabled (fugit gem not loaded)`

The `fugit` gem is missing. This should not happen in the published
Docker image; it usually means a bare Ruby install or custom image left
the optional cron dependency out. All cron interfaces are no-ops until
the gem is available.

#### %SCHED-4-AUTOPULL_BAD

Severity 4. Format:

    auto-pull interval invalid interface=<name> value=<...>

`auto-pull` value on a `local_repo` interface failed to parse.

#### %SCHED-4-NOT_GIT

Severity 4. Format:

    auto-pull skipped: not a git checkout interface=<name> path=<...>

The `local_repo` path on disk isn't a git work tree. Auto-pull is a
no-op for this interface.

#### %SCHED-6-PULL_OK

Severity 6. Format:

    auto-pull succeeded interface=<name> ref=<sha> changed=<true|false>

A scheduled `git pull` ran. `changed=true` means HEAD moved.

#### %SCHED-4-PULL_FAILED

Severity 4. Format:

    auto-pull non-zero exit interface=<name> exit_status=<n>

The `git pull` exited non-zero. Daemon keeps the previous checkout.

#### %SCHED-3-PULL_ERR

Severity 3. Format:

    auto-pull errored interface=<name> error=<class> message=<...>

`git pull` raised an exception (e.g. host not reachable, auth failure).

#### %SCHED-3-TICK_ERR

Severity 3. Format:

    scheduler tick crashed error=<class> message=<...>

The whole scheduler tick raised. Should never fire — file a bug if it
shows up in production logs.

### RECOV — boot-time crash recovery

#### %RECOV-5-SWEPT

Severity 5. Format:

    swept abandoned state on boot
      requeued_jobs=<n> failed_runs=<n> failed_steps=<n>
      containers_killed=<n> lock_timeout_s=<n>

On daemon startup, `Recovery.sweep` re-queued jobs that were locked by
a previous (now-dead) worker, marked truly orphaned runs/steps as
failed, and killed any leaked docker containers tagged with a
`prouterd.run_uid` no longer associated with a live run. Only emitted
when something was actually swept.

#### %RECOV-4-ORPHAN_FAIL

Severity 4. Format:

    orphan-container sweep failed error=<class> message=<...>

Recovery's docker-side sweep raised. Daemon continues; non-orphan
recovery still completed.

### API — HTTP API errors

#### %API-3-INTERNAL

Severity 3. Format:

    internal server error error=<class> message=<...>

A handler raised an uncaught exception. Returns 500 to the client.

#### %API-4-CANCEL_KILL_FAIL

Severity 4. Format:

    cancel: container kill failed run_uid=<uid> container=<id> error=<class> message=<...>

`prouter cancel` reached the docker-kill stage but the kill itself
failed (container already gone, docker daemon unreachable, etc). The
cancel still succeeds at the run level.
