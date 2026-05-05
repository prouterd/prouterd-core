# Examples

Twelve runnable `.prc` files, each demonstrating one feature in
isolation (or, for `10_tg_github` and `12_jira_debug`, a full
real-world pipeline).

The base install of `prouterd` covers `interface shell`, `interface
http`, `interface llm`, `interface webhook`, `interface manual` —
all on Ruby stdlib (`Open3`, `Net::HTTP`). `interface docker`,
`interface postgres`, and `interface cron` are opt-in:

```
gem install docker-api   # interface docker
gem install pg           # interface postgres
gem install fugit        # interface cron
```

| File                         | Demonstrates                                                          |
| ---------------------------- | --------------------------------------------------------------------- |
| `01_hello_world.prc`         | smallest pipeline; `interface shell`; `{{event.name}}` templating     |
| `02_conditional_routing.prc` | `match` conditions on outgoing routes; backtick raw strings; stdout-as-JSON |
| `03_retries.prc`             | retry policy with exponential backoff (always-fail demo)              |
| `04_webhook.prc`             | webhook interface + bearer auth                                       |
| `05_cron.prc`                | cron interface + scheduler (requires `gem install fugit`)             |
| `06_shell_block.prc`         | mixed `interface shell` + `interface docker` blocks in one process    |
| `07_contract.prc`            | output JSON contract + `on violation` policy                          |
| `08_typed_artifacts.prc`     | named files between blocks (`produces` / `input … from …`)            |
| `09_llm.prc`                 | `interface llm claude`; ticket summarization via Anthropic            |
| `10_tg_github/`              | full pipeline: GitHub webhook → format → Telegram (shell-only)        |
| `11_retry_when.prc`          | smart retries: `retry when error_type in …` + `{{previous}}`          |
| `12_jira_debug/`             | end-to-end: webhook → http (Jira) → postgres → llm → http             |

Each file's top comment shows the exact commands to run it.

## A complete walkthrough

```bash
DB=/tmp/prouterd-demo.db
rm -f $DB

# 1. Apply (commit it as version 1)
prouter apply examples/02_conditional_routing.prc --db $DB

# 2. Trace what would happen with an event (no execution)
echo '{}' > /tmp/event.json
prouter trace event /tmp/event.json --interface cli --db $DB

# 3. Trigger the pipeline (--runner shell so no docker is involved)
prouter trigger process score_pipe input /tmp/event.json --db $DB --runner shell

# 4. Inspect the run
prouter exec "show runs" --db $DB
RUN=$(prouter exec "show runs" --db $DB | tail -1 | awk '{print $1}')
prouter exec "show run $RUN"          --db $DB
prouter exec "show logs run $RUN"     --db $DB

# 5. Replay (with same input + same config commit)
prouter replay run $RUN --db $DB

# 6. Replay starting from a chosen block (skips earlier blocks)
prouter replay run $RUN from notify_sales --db $DB
```

## Webhook demo

```bash
DB=/tmp/prouterd-webhook.db
rm -f $DB

export WEBHOOK_TOKEN=demo-token
prouter apply examples/04_webhook.prc --db $DB
prouterd --db $DB --port 8089 &
SERVER_PID=$!
sleep 0.5

curl -s -X POST http://127.0.0.1:8089/i/leads_in \
  -H "Authorization: Bearer demo-token" \
  -d '{"type":"lead.created","body":{"name":"Acme"}}'
# -> {"run_id":"run_xxxxxxxx","status":"queued"}

sleep 1
prouter exec "show runs" --db $DB

kill -INT $SERVER_PID
```

## Cron demo (waits ~70 seconds for a minute boundary)

Requires `gem install fugit`. Without fugit the daemon still runs
fine — cron interfaces just never fire and the scheduler logs a
single warning.

```bash
DB=/tmp/prouterd-cron.db
rm -f $DB

prouter apply examples/05_cron.prc --db $DB
prouterd --db $DB --port 8090 &
SERVER_PID=$!

# Wait for a minute boundary, then check
sleep 70
prouter exec "show runs" --db $DB

kill -INT $SERVER_PID
```
