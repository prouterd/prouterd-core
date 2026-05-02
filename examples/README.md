# Examples

Five runnable `.prc` files, each demonstrating one feature. Every
example fits in one file and uses only `alpine:latest` so you only need
Docker available — no custom images.

| File                            | Demonstrates                              |
|---------------------------------|-------------------------------------------|
| `01_hello_world.prc`            | minimal pipeline (one block, no routes)   |
| `02_conditional_routing.prc`    | `match` conditions on outgoing routes     |
| `03_retries.prc`                | retry policy with exponential backoff     |
| `04_webhook.prc`                | webhook interface + bearer auth           |
| `05_cron.prc`                   | cron interface + scheduler                |
| `06_shell_block.prc`            | mixed `type shell` + `type docker` blocks |
| `07_contract.prc`               | output JSON contract + `on violation` policy |

Each file's top comment shows the exact commands to run it. Common setup:

```bash
docker pull alpine:latest
DB=/tmp/prouterd-demo.db
rm -f $DB
```

## A complete walkthrough

```bash
DB=/tmp/prouterd-demo.db
rm -f $DB

# 1. Apply (commit it as version 1)
bundle exec ruby exe/prouter apply examples/02_conditional_routing.prc --db $DB

# 2. Trace what would happen with an event (no execution)
echo '{}' > /tmp/event.json
bundle exec ruby exe/prouter trace event /tmp/event.json \
  --interface cli --db $DB

# 3. Trigger the pipeline
bundle exec ruby exe/prouter trigger process score_pipe \
  input /tmp/event.json --db $DB

# 4. Inspect the run
bundle exec ruby exe/prouter exec "show runs" --db $DB
RUN=$(bundle exec ruby exe/prouter exec "show runs" --db $DB | tail -1 | awk '{print $1}')
bundle exec ruby exe/prouter exec "show run $RUN" --db $DB
bundle exec ruby exe/prouter exec "show logs run $RUN" --db $DB

# 5. Replay (with same input + same config commit)
bundle exec ruby exe/prouter replay run $RUN --db $DB

# 6. Replay starting from a chosen block (skips earlier blocks)
bundle exec ruby exe/prouter replay run $RUN from notify_sales --db $DB
```

## Webhook demo

```bash
DB=/tmp/prouterd-webhook.db
rm -f $DB

export WEBHOOK_TOKEN=demo-token
bundle exec ruby exe/prouter apply examples/04_webhook.prc --db $DB
bundle exec ruby exe/prouterd --db $DB --port 8089 &
SERVER_PID=$!
sleep 0.5

curl -s -X POST http://127.0.0.1:8089/i/leads_in \
  -H "Authorization: Bearer demo-token" \
  -d '{"type":"lead.created","body":{"name":"Acme"}}'
# -> {"run_id":"run_xxxxxxxx","status":"queued"}

sleep 1
bundle exec ruby exe/prouter exec "show runs" --db $DB

kill -INT $SERVER_PID
```

## Cron demo (waits ~70 seconds for a minute boundary)

```bash
DB=/tmp/prouterd-cron.db
rm -f $DB

bundle exec ruby exe/prouter apply examples/05_cron.prc --db $DB
bundle exec ruby exe/prouterd --db $DB --port 8090 &
SERVER_PID=$!

# Wait for a minute boundary, then check
sleep 70
bundle exec ruby exe/prouter exec "show runs" --db $DB

kill -INT $SERVER_PID
```
