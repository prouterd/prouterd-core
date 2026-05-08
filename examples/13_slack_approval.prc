! Slack approval pattern, composed from existing primitives — no
! Slack-specific iface plugin needed.
!
! Flow:
!   1. Some upstream process triggers `access_request`, which:
!      - posts an interactive message to Slack via `interface http slack_out`
!        (the `block_id` field carries the run's thread_id so the click
!        handler can find this run later)
!      - hits a `pause` block — the run goes to status="paused",
!        unlocking the daemon for other work
!   2. Operator clicks "approve" or "deny" in Slack.
!   3. Slack POSTs the interaction payload to /i/slack_in. The
!      `interface webhook` HMAC-verifies `x-slack-signature` against
!      SLACK_SIGNING_SECRET, then triggers the `slack_resume` process.
!   4. `slack_resume` calls the daemon's own
!      `POST /v1/runs/by-thread/:tid/resume` endpoint over HTTP, with
!      the approver's choice in the body. The original
!      `access_request` resumes from the block immediately downstream
!      of `wait`.
!
! Why HTTP self-call instead of `interface shell` + `prouter resume`:
!   the body templater renders Hash/Array values as JSON automatically
!   (see Util::Templater), so embedding {{event.user.name}} inside a
!   body-json template is shell-injection-free. A `shell exec` with
!   single-quoted JSON would break on apostrophes in field values and
!   open a shell-injection surface. The endpoint is also useful to any
!   external caller that knows the thread_id.
!
! Setup:
!   $ export SLACK_BOT_TOKEN="xoxb-..."           # from your Slack app
!   $ export SLACK_SIGNING_SECRET="abc123..."     # signing secret
!   $ export PROUTERD_ADMIN_TOKEN="..."           # bearer for /v1
!   $ prouter apply examples/13_slack_approval.prc --db /tmp/o.db

router demo
exit

secret SLACK_BOT_TOKEN
 source env SLACK_BOT_TOKEN
exit
secret SLACK_SIGNING_SECRET
 source env SLACK_SIGNING_SECRET
exit
secret PROUTERD_ADMIN_TOKEN
 source env PROUTERD_ADMIN_TOKEN
exit

! ----- outbound: post the message + suspend -----

interface http slack_out
 base-url "https://slack.com/api"
 auth bearer secret SLACK_BOT_TOKEN
exit

interface manual cli
 no shutdown
exit

process access_request
 thread-id "{{event.thread_id}}"

 block ask
  interface http slack_out
  method POST
  path "/chat.postMessage"
  body-json `{"channel":"#access","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"Grant {{event.user}} access to {{event.repo}}? Reason: {{event.reason}}"}},{"type":"actions","block_id":"{{event.thread_id}}","elements":[{"type":"button","text":{"type":"plain_text","text":"approve"},"value":"approve","action_id":"approve"},{"type":"button","text":{"type":"plain_text","text":"deny"},"value":"deny","action_id":"deny","style":"danger"}]}]}`
 exit

 block wait
  pause "awaiting approver decision"
 exit

 block apply_change
  interface http slack_out
  method POST
  path "/chat.postMessage"
  body-json `{"channel":"#access","text":"✅ {{wait.approver_name}} approved access for {{event.user}} to {{event.repo}}"}`
  skip-when wait.decision eq "deny"
 exit

 route ask wait
 route wait apply_change
exit

route interface cli process access_request
exit

! ----- inbound: webhook receives the click, HTTP-resumes the paused run -----

interface webhook slack_in
 path /slack_in
 method POST
 ! Slack signs the body with the app's signing secret. The handler
 ! HMAC-verifies before triggering this process; `v0=` (Slack) /
 ! `sha256=` (GitHub) prefixes are stripped automatically.
 hmac-sha256 secret SLACK_SIGNING_SECRET header x-slack-signature
exit

interface http daemon_self
 base-url "http://127.0.0.1:8080"
 auth bearer secret PROUTERD_ADMIN_TOKEN
exit

! Slack interaction body looks roughly like:
!   {
!     "type": "block_actions",
!     "actions": [{ "value": "approve", "block_id": "<thread_id>", ... }],
!     "user":    { "id": "U01ABC", "name": "alice" },
!     "container": { "thread_ts": "...", "channel_id": "..." }
!   }
! `block_id` is the thread_id we set on the message (no prefix), so
! /v1/runs/by-thread/<that>/resume finds the right paused run.
process slack_resume
 block resume
  interface http daemon_self
  method POST
  path "/v1/runs/by-thread/{{event.actions.0.block_id}}/resume"
  body-json `{"value":{"decision":"{{event.actions.0.value}}","approver_id":"{{event.user.id}}","approver_name":"{{event.user.name}}"}}`
 exit
exit

route interface slack_in process slack_resume
exit
