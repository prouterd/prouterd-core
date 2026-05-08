! Slack approval pattern, composed from existing primitives — no
! Slack-specific iface plugin needed.
!
! Flow:
!   1. Some upstream process triggers `access_request`, which:
!      - posts an interactive message to Slack via `interface http slack_out`
!        (button payload encodes the run's thread_id so the click can
!        find this run later)
!      - hits a `pause` block — the run goes to status="paused",
!        unlocking the daemon for other work
!   2. Operator clicks "approve" or "deny" in Slack.
!   3. Slack POSTs the interaction payload to /i/slack_in. The
!      `interface webhook` HMAC-verifies `x-slack-signature` against
!      SLACK_SIGNING_SECRET, then triggers the `slack_resume` process.
!   4. `slack_resume` shells out to `prouter resume run-by-thread <id>
!      --value <decision>`, which wakes the paused run with the
!      approver's choice. The original `access_request` resumes from
!      the block immediately downstream of `wait`.
!
! Setup:
!   $ export SLACK_BOT_TOKEN="xoxb-..."           # from your Slack app
!   $ export SLACK_SIGNING_SECRET="abc123..."     # signing secret
!   $ prouter apply examples/13_slack_approval.prc --db /tmp/o.db

router demo
exit

secret SLACK_BOT_TOKEN
 source env SLACK_BOT_TOKEN
exit
secret SLACK_SIGNING_SECRET
 source env SLACK_SIGNING_SECRET
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
  body-json `{"channel":"#access","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"Grant {{event.user}} access to {{event.repo}}? Reason: {{event.reason}}"}},{"type":"actions","block_id":"approve_{{event.thread_id}}","elements":[{"type":"button","text":{"type":"plain_text","text":"approve"},"value":"approve","action_id":"approve"},{"type":"button","text":{"type":"plain_text","text":"deny"},"value":"deny","action_id":"deny","style":"danger"}]}]}`
 exit

 block wait
  pause "awaiting approver decision"
 exit

 block apply_change
  interface shell host
  exec "echo decision={{wait.decision}} approver={{wait.approver_id}}"
  skip-when wait.decision eq "deny"
 exit

 route ask wait
 route wait apply_change
exit

route interface cli process access_request
exit

! ----- inbound: webhook receives the click, resumes the paused run -----

interface webhook slack_in
 path /slack_in
 method POST
 ! Slack signs the body with the app's signing secret. The handler
 ! HMAC-verifies before triggering this process; `v0=` (Slack) /
 ! `sha256=` (GitHub) prefixes are stripped automatically.
 hmac-sha256 secret SLACK_SIGNING_SECRET header x-slack-signature
exit

interface shell host
exit

! Slack interaction body looks roughly like:
!   {
!     "type": "block_actions",
!     "actions": [{ "value": "approve", ... }],
!     "user":    { "id": "U01ABC", "name": "alice" },
!     "container": { "thread_ts": "...", "channel_id": "..." }
!   }
! and the block_id we set above ("approve_<thread_id>") carries the
! thread_id we want to resume.
process slack_resume
 block resume
  interface shell host
  exec `prouter resume run-by-thread {{event.actions.0.block_id}} --value '{"decision":"{{event.actions.0.value}}","approver_id":"{{event.user.id}}","approver_name":"{{event.user.name}}"}' --db /var/prouterd.db`
 exit
exit

route interface slack_in process slack_resume
exit
