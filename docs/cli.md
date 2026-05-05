# CLI & HTTP reference

Two binaries:

- `prouter` — operator CLI, one-shot subcommands
- `prouterd` — long-running daemon (HTTP + cron + workers)

## prouter (operator CLI)

```
prouter check  <file>                         parse + validate
prouter render <file>                         emit canonical config
prouter apply  <file> [--db PATH]             commit a config snapshot

prouter shell  [--db PATH] [--config FILE]    router-style interactive
prouter exec   "<cmd>" [--db PATH]            one-shot shell command

prouter trigger process <name> input <file>   enqueue a run
prouter trace   event <file> [--interface N]  static analysis (no execution)

prouter replay  run <uid> [from <block>]
prouter cancel  run <uid>                     soft cancel (between-level)
prouter diff    <file>                        diff file vs running config
prouter cleanup --older-than 30d              delete terminal runs
                [--dry-run] [--batch-size N]

prouter version | help
```

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
process-router# trigger process triage input event.json
process-router# exit
```

Mode stack: user `>`, privileged `#`, `(config)#`, `(config-process)#`,
`(config-block)#`, etc. Tab completion + router-style prefix
abbreviation everywhere — `sh ru` resolves to `show running-config`.

`configure terminal` enters a candidate buffer; `commit` validates and
persists, `abort` discards.
