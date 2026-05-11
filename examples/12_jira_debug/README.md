# 12. Jira-debug — webhook → http → postgres → llm → http

End-to-end debug workflow tying together every outbound interface
type prouterd ships with.

```
inbound:  interface webhook jira_in
            └─▶ process triage_pipeline
                  ├─ block fetch_ticket    (interface http      jira)
                  ├─ block recent_history  (interface postgres  warehouse)
                  ├─ block summarize       (interface llm       claude)
                  └─ block post_comment    (interface http      jira)
```

A Jira automation rule POSTs to `/i/jira_in` when a ticket lands in
the "Needs Triage" column. The pipeline:

1. **fetch_ticket** — pulls the full ticket detail from Jira's REST
   API. `path "/issue/{{event.issue.key}}"` templates against the
   inbound webhook payload.
2. **recent_history** — looks up the last 20 closed tickets in the
   same component via postgres. `params "{{fetch_ticket.fields.components.0.name}}"`
   threads the dotted-path context lookup straight into the SQL bind.
3. **summarize** — asks Claude for a concise debug brief, prompt-
   templated with the ticket body and the recent-history rows. On
   retries, `{{iteration}}` and `{{previous.error_type}}` give the
   model awareness of prior failures.
4. **post_comment** — POSTs the summary back to Jira as a comment.

## Why this example

It demonstrates, end-to-end:

- **Inbound webhook + bearer auth** — `interface webhook` + `auth
  bearer secret WEBHOOK_TOKEN`.
- **Templated outbound HTTP path** — `path "/issue/{{event.issue.key}}"`.
- **Cross-block context flow** — `{{fetch_ticket.fields.components.0.name}}`
  references the auto-stored output of the upstream block (no
  `input`/`output` directives — outputs key on `block.name`).
- **Postgres parameter binding** — `params "..."` becomes `$1` in the
  SQL. Comma-separated values map to `$1..$N`.
- **LLM call with system prompt + iteration / previous templating**.
- **Smart retries** — one `policy transient_only` shared by all four
  blocks, with `retry when error_type in "timeout","http_status","http_error","llm_error","sql_error"`
  so we retry on transient failures but not on `invalid_call` /
  `invalid_interface`.

## Required setup

Install the optional gems for postgres + LLM:

```
gem install pg
```

(`http` and `llm` ride on `Net::HTTP`; `webhook` is core. No
docker-api needed for this pipeline — every block is shell-free
HTTP/SQL.)

Env vars:

| Variable        | What it is                                      |
| --------------- | ----------------------------------------------- |
| `JIRA_TOKEN`    | Jira REST API token                             |
| `PG_DSN`        | postgres connection string for analytics DB     |
| `CLAUDE_KEY`    | Anthropic API key                               |
| `WEBHOOK_TOKEN` | bearer the inbound webhook checks               |

## Running it

```bash
prouter apply examples/12_jira_debug/jira_debug.prc --db /tmp/prouterd.db
prouterd --db /tmp/prouterd.db   # start the daemon

# Trigger from the inbound side:
curl -X POST http://localhost:8080/i/jira_in \
  -H "authorization: Bearer $WEBHOOK_TOKEN" \
  -H "content-type: application/json" \
  -d '{"issue":{"key":"PROJ-123","fields":{"summary":"login fails after MFA","status":{"name":"Needs Triage"}}}}'

# Inspect:
printf "enable\nshow runs\n" | prouter shell --db /tmp/prouterd.db
printf "enable\nshow run <uid>\n" | prouter shell --db /tmp/prouterd.db
printf "enable\nshow logs run <uid>\n" | prouter shell --db /tmp/prouterd.db
```
