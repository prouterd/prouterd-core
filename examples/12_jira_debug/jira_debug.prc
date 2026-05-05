! End-to-end debug workflow tying together the new outbound interfaces:
!
!     webhook  -> http (Jira)  ----+
!                                  |
!                  postgres  -> llm (Claude) -> http (Jira comment)
!
! 1. A Jira automation rule webhooks us when a ticket lands in the
!    "needs triage" column.
! 2. fetch_ticket  : pulls the full ticket detail from Jira's REST API.
! 3. recent_history: looks up similar tickets in our analytics warehouse
!                    via postgres, scoped to the same component.
! 4. summarize     : asks Claude to draft a one-paragraph debug brief
!                    from the ticket body + nearby history.
! 5. post_comment  : POSTs the summary back to Jira as an internal comment.
!
! Smart retries: HTTP/LLM/postgres errors retry; auth errors don't. On
! retry, the LLM prompt gets {{previous.error_type}} so it knows what
! the prior failure looked like.
!
! Required env vars:
!   JIRA_TOKEN          — Jira REST API token
!   PG_DSN              — postgres connection string for analytics warehouse
!   CLAUDE_KEY          — Anthropic API key
!   WEBHOOK_TOKEN       — bearer for the inbound webhook
!
!     prouter apply examples/12_jira_debug/jira_debug.prc --db /tmp/prouterd.db
!     prouterd --db /tmp/prouterd.db
!   # Trigger from the inbound side:
!     curl -X POST http://localhost:8080/i/jira_in \
!       -H "authorization: Bearer $WEBHOOK_TOKEN" \
!       -H "content-type: application/json" \
!       -d '{"issue":{"key":"PROJ-123","fields":{"summary":"login fails after MFA"}}}'

router prouter-debug
exit

queue default
 concurrency 4
 timeout 5m
exit

policy transient_only
 retry attempts 3
 retry backoff exponential
 retry initial-delay 1s
 retry max-delay 30s
 retry when error_type in "timeout","http_status","http_error","llm_error","sql_error"
exit

! ----- secrets -----

secret JIRA_TOKEN
 source env JIRA_TOKEN
exit

secret PG_DSN
 source env PG_DSN
exit

secret CLAUDE_KEY
 source env CLAUDE_KEY
exit

secret WEBHOOK_TOKEN
 source env WEBHOOK_TOKEN
exit

! ----- inbound: webhook from Jira automation -----

interface webhook jira_in
 path /jira-trigger
 method POST
 auth bearer secret WEBHOOK_TOKEN
 no shutdown
exit

! ----- outbound: external services we call -----

interface http jira
 base-url https://acme.atlassian.net/rest/api/3
 auth bearer secret JIRA_TOKEN
exit

interface postgres warehouse
 dsn "{{secret.PG_DSN}}"
 statement-timeout 5000
exit

interface llm claude
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

! ----- pipeline -----

process triage_pipeline
 description "Auto-triage incoming Jira tickets with a debug brief"
 queue default
 no shutdown

 ! 1) Pull the full ticket from Jira so we have the description, labels,
 !    component, etc. — the inbound webhook only carries a few fields.
 block fetch_ticket
  interface http jira
  retry policy transient_only
  method GET
  path "/issue/{{event.issue.key}}"
  timeout 10s
  enable
 exit

 ! 2) Look up the last 20 closed tickets in the same component to give
 !    the LLM nearby history. params bind to $1.
 block recent_history
  interface postgres warehouse
  retry policy transient_only
  query "SELECT key, summary, resolution FROM tickets WHERE component = $1 AND status = 'closed' ORDER BY closed_at DESC LIMIT 20"
  params "{{fetch_ticket.fields.components.0.name}}"
  timeout 10s
  enable
 exit

 ! 3) Ask Claude for a debug brief. {{iteration}} + {{previous.error_type}}
 !    let the model see if a prior attempt failed (e.g. context too long).
 block summarize
  interface llm claude
  retry policy transient_only
  system "You write concise debug briefs for engineers. Output 3-5 sentences. No fluff."
  prompt "Ticket: {{fetch_ticket.fields.summary}}\n\nDescription:\n{{fetch_ticket.fields.description}}\n\nRecent similar tickets:\n{{recent_history.rows}}\n\n(attempt {{iteration}}, last error: {{previous.error_type}})"
  max-tokens 600
  temperature 0.2
  timeout 30s
  enable
 exit

 ! 4) Post the brief back to Jira as a comment on the original issue.
 block post_comment
  interface http jira
  retry policy transient_only
  method POST
  path "/issue/{{event.issue.key}}/comment"
  body-json `{"body":{{summarize.text}}}`
  timeout 10s
  enable
 exit

 route fetch_ticket recent_history
 route recent_history summarize
 route summarize post_comment
exit

! ----- wire inbound to process -----

route interface jira_in process triage_pipeline
 match event.issue.fields.status.name eq "Needs Triage"
exit
