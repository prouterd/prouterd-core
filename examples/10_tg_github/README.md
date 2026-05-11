# GitHub → Telegram notifications

A complete prouterd pipeline: GitHub sends a webhook on issue/PR events,
prouterd filters by event type, formats a Markdown message in a Ruby
block, and posts it to a Telegram chat via the Bot API.

Two blocks per pipeline:
- `format_*.rb` — Ruby script extracts fields and builds the Markdown text
- `send` — inline `curl` shell block, no script file

No Docker. Host needs `ruby`, `curl`, `jq` on PATH.

## Files

```
tg_github.prc            # router, secrets, interface, two pipelines
blocks/format_pr.rb      # PR event → {"text": "..."}
blocks/format_issue.rb   # issue event → {"text": "..."}
```

## Quickstart

```bash
# 1. Telegram bot — get token from @BotFather, then chat_id from
#    https://api.telegram.org/bot<TOKEN>/getUpdates after messaging the bot.
export TG_BOT_TOKEN="123456:AA..."
export TG_CHAT_ID="123456789"

# 2. GitHub webhook secret — pick anything random.
export GH_WEBHOOK_SECRET="$(openssl rand -hex 32)"

# 3. Daemon admin token (for /v1/* HTTP endpoints).
export PROUTERD_ADMIN_TOKEN="$(openssl rand -hex 16)"

# 4. Apply the config and start the daemon.
DB=/tmp/tg-github.db
rm -f $DB
bundle exec exe/prouter apply examples/10_tg_github/tg_github.prc --db $DB
bundle exec exe/prouterd --port 8080 --db $DB &
SERVER=$!
sleep 1

# 5. Smoke test with a fake GitHub PR-opened payload.
cat > /tmp/pr_opened.json <<'JSON'
{
  "action": "opened",
  "pull_request": {
    "title": "Fix the thing",
    "html_url": "https://github.com/example/repo/pull/42",
    "draft": false,
    "user": { "login": "alice" }
  },
  "repository": { "full_name": "example/repo" }
}
JSON

curl -s -X POST http://127.0.0.1:8080/i/github \
  -H "Authorization: Bearer $GH_WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  -d @/tmp/pr_opened.json
# → {"run_id":"run_xxxxx","status":"queued"}

# Watch your Telegram chat — the bot should post the formatted message.

# 6. Inspect the run.
sleep 1
printf "enable\nshow runs\n" | bundle exec exe/prouter shell --db $DB
RUN=$(printf "enable\nshow runs\n" | bundle exec exe/prouter shell --db $DB | tail -1 | awk '{print $1}')
printf "enable\nshow run $RUN\n" | bundle exec exe/prouter shell --db $DB
printf "enable\nshow logs run $RUN\n" | bundle exec exe/prouter shell --db $DB

# Cleanup.
kill -INT $SERVER
```

## Connecting GitHub for real

In the repo: **Settings → Webhooks → Add webhook**:

| Field         | Value                                  |
|---------------|----------------------------------------|
| Payload URL   | `https://your-host/i/github`           |
| Content type  | `application/json`                     |
| Secret        | matches `GH_WEBHOOK_SECRET` env on the daemon |
| Events        | tick "Issues" + "Pull requests"        |

GitHub sends the secret as a Bearer header on each request — prouterd's
`auth bearer secret GH_WEBHOOK_SECRET` clause checks it constant-time.

## What the .prc demonstrates

- **`secret … source env`** for three different tokens — none of them in
  the config text, all read from daemon env at run time.
- **`policy retry_tg`** — exponential backoff specifically for the
  network call to Telegram. The format step is deterministic; we don't
  retry it, only the send.
- **`queue notify` + concurrency 4** — bounded parallelism so a flood
  of GitHub events doesn't DoS the Telegram API.
- **Webhook auth** via `auth bearer secret`.
- **Conditional global routes** — one webhook URL, two pipelines, picked
  by content of the body:
  ```
  match event.pull_request exists
  match event.action in "opened","ready_for_review","closed"
  match event.pull_request.draft eq false
  ```
  Drafts and label-only edits don't trigger anything (router returns
  422 to GitHub).
- **`interface shell`** — no Docker daemon needed; blocks run as
  host Ruby processes via `Open3`. Default install covers this; no
  extra gem required.

## Tweaking safely

Operator can change behavior without redeploy by editing the `.prc`,
reviewing the semantic diff, and applying a new config commit:

```bash
bundle exec exe/prouter diff examples/10_tg_github/tg_github.prc --db $DB
bundle exec exe/prouter apply examples/10_tg_github/tg_github.prc --db $DB
```

History is visible in `show config commits`. Roll back from the shell
with `rollback commit <id>`.
