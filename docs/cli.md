# CLI & HTTP reference

Two binaries:

- `prouter` — operator CLI, one-shot subcommands
- `prouterd` — long-running daemon (HTTP + cron + workers)

## prouter (operator CLI)

```
prouter check    <file>                       parse + validate
prouter validate <file> [--against running]   lint, or semantic diff vs running
prouter render   <file>                       emit canonical config
prouter apply    <file> [--db PATH]           commit a config snapshot

prouter shell    [--db PATH] [--config FILE]  read-only operator shell
                                              (`show *`, `apply <file>`,
                                              `rollback commit X`, etc)

prouter trigger  process <name> input <file>  enqueue a run

prouter replay   run <uid> [from <block>]
prouter resume   run <uid>          [--value <json>]
prouter resume   run-by-thread <id> [--value <json>]
prouter cancel   run <uid>                    soft cancel (between-level)
prouter diff     <file>                       diff file vs running config

prouter version | help
```

Static routing analysis lives at `POST /v1/trace` on the daemon (no
dedicated `prouter` subcommand). Run retention is now expected to be
driven externally — see [`production.md`](production.md#retention) for
the recipe.

### Common flags

| Flag             | Meaning                                                       |
| ---------------- | ------------------------------------------------------------- |
| `--db PATH`      | SQLite path (default `var/prouterd.db`, env `PROUTERD_DB`)    |
| `--config FILE`  | load this `.prc` file as the running config (in-memory)       |
| `--no-db`        | in-memory mode for read-only commands; mutating commands need `--db` |

## prouterd (daemon)

```
prouterd [--bind ADDR] [--port N] [--workers N] [--db PATH]
                                                HTTP daemon: webhooks +
                                                cron + /v1 API
prouterd --version | --help
```

Graceful shutdown: SIGINT/SIGTERM stops accepting state-changing
requests (503), drains in-flight runs (30s default), then stops Puma.

### Endpoints

| Endpoint                                               | Auth      | Purpose                          |
| ------------------------------------------------------ | --------- | -------------------------------- |
| `GET  /v1/status`                                      | open      | health, commit pointers          |
| `GET  /metrics`                                        | open      | Prometheus text format           |
| `POST /i/<interface>`                                  | per-iface | webhook ingestion                |
| `GET  /v1/config/{running,startup,commits[/:id]}`      | admin     | inspect config history           |
| `POST /v1/config/{check,apply,rollback}`               | admin     | mutate config                    |
| `GET  /v1/processes[/:name]`                           | admin     | list / detail                    |
| `POST /v1/processes/:name/trigger`                     | admin     | enqueue a run                    |
| `GET  /v1/runs[?process=&status=]`                     | admin     | list                             |
| `GET  /v1/runs/:uid[/logs[?stream=&block=],/artifacts]` | admin    | inspect                          |
| `POST /v1/runs/:uid/{replay,cancel}`                   | admin     | re-run / soft + hard cancel      |
| `POST /v1/trace`                                       | admin     | static routing analysis          |
| `GET  /v1/events`                                      | admin     | WebSocket — live run / log feed  |

Admin auth: bearer token from `PROUTERD_ADMIN_TOKEN` env var. If unset,
`/v1/*` routes are open — fine for local dev; the daemon prints a
warning at boot.

## Interactive shell

```
$ prouter shell --db var/prouterd.db
process-router> enable
process-router# show running-config
process-router# show runs
process-router# apply triage.prc
process-router# rollback commit 11
process-router# replay run run_ab6a5e49
process-router# exit
```

Two modes: user `>` (read-only) and privileged `#` (`enable` to enter,
`disable` to leave). Tab completion + router-style prefix abbreviation
everywhere — `sh ru` resolves to `show running-config`.

Configuration is text — edit `.prc` in your editor, then `apply <file>`
from the shell (or `prouter apply` from the CLI) to commit it. The
shell is a read-only operator surface: `show *`, `apply`, `rollback
commit X`, `replay run X`, `cancel run X`, `write memory`. The
in-shell candidate-config editor (`configure terminal`) was removed
in Phase 40 — operators were editing `.prc` in their preferred editor
anyway.

Stdin is honored when not a TTY, so scripts can pipe commands:

```bash
printf "enable\nshow runs\n" | prouter shell --db var/prouterd.db
```
