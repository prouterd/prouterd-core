! GitHub webhooks → Telegram notifications.
!
! Pipeline:
!   POST /i/github  →  match (PR or issue, real action only)  →
!     format Markdown message  →  POST to Telegram Bot API
!
! Setup (host-side, no Docker required):
!
!   1. Telegram bot:
!      - Create via @BotFather, save the token.
!      - Send the bot any message, then visit
!        https://api.telegram.org/bot<TOKEN>/getUpdates
!        and copy the chat_id of the message.
!
!   2. GitHub repo:
!      - Settings → Webhooks → Add webhook
!      - Payload URL:    https://<your-host>/i/github
!      - Content type:   application/json
!      - Secret:         arbitrary, save as GH_WEBHOOK_SECRET
!      - Events:         "Issues" + "Pull requests"
!
!   3. Run the daemon:
!      $ export GH_WEBHOOK_SECRET=<your-secret>
!      $ export TG_BOT_TOKEN=<bot-token>
!      $ export TG_CHAT_ID=<chat-id>
!      $ export PROUTERD_ADMIN_TOKEN=$(openssl rand -hex 16)
!      $ bundle exec exe/prouterd --port 8080 --db /var/lib/prouterd/db
!
!   4. Apply:
!      $ prouter apply examples/10_tg_github/tg_github.prc \
!          --db /var/lib/prouterd/db

router gh_relay
 hostname gh-relay-01
exit

! ----- secrets (read from daemon env) -----

secret GH_WEBHOOK_SECRET
 source env GH_WEBHOOK_SECRET
exit
secret TG_BOT_TOKEN
 source env TG_BOT_TOKEN
exit
secret TG_CHAT_ID
 source env TG_CHAT_ID
exit

! ----- retry policy for the network call to Telegram -----

policy retry_tg
 retry attempts 3
 retry backoff exponential
 retry initial-delay 1s
 retry max-delay 30s
exit

! ----- queue: bound parallelism so we don't hammer Telegram -----

queue notify
 concurrency 4
 timeout 30s
exit

! ----- interfaces -----

interface webhook github_in
 path /i/github
 method POST
 auth bearer secret GH_WEBHOOK_SECRET
 no shutdown
exit

interface shell ruby_blocks
 cwd ./examples/10_tg_github
exit

! ----- pipeline: pull requests -----

process pr_notify
 description "Format and post a PR notification to Telegram"
 queue notify
 no shutdown

 block format
  interface shell ruby_blocks
  exec "ruby blocks/format_pr.rb"
  timeout 5s
  enable
 exit

 block send
  interface shell ruby_blocks
  exec `sh -c 'TEXT=$(jq -r .input.text "$PROUTER_INPUT_PATH") && curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "parse_mode=Markdown" --data-urlencode "text=$TEXT" -o "$PROUTER_OUTPUT_PATH"'`
  secret TG_BOT_TOKEN
  secret TG_CHAT_ID
  retry retry_tg
  timeout 10s
  enable
 exit

 route format send
exit

! ----- pipeline: issues -----

process issue_notify
 description "Format and post an issue notification to Telegram"
 queue notify
 no shutdown

 block format
  interface shell ruby_blocks
  exec "ruby blocks/format_issue.rb"
  timeout 5s
  enable
 exit

 block send
  interface shell ruby_blocks
  exec `sh -c 'TEXT=$(jq -r .input.text "$PROUTER_INPUT_PATH") && curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "parse_mode=Markdown" --data-urlencode "text=$TEXT" -o "$PROUTER_OUTPUT_PATH"'`
  secret TG_BOT_TOKEN
  secret TG_CHAT_ID
  retry retry_tg
  timeout 10s
  enable
 exit

 route format send
exit

! ----- routing: event → process, with conditions -----
!
! GitHub sends one webhook URL for many events. We dispatch by content:
!   - PRs: opened / ready_for_review / closed, but NOT drafts
!   - issues: opened only (skips edits / labels / assignments)
! Anything else returns 422 from /i/github (no matching route).

route interface github_in process pr_notify
 match event.pull_request exists
 match event.action in "opened","ready_for_review","closed"
 match event.pull_request.draft eq false
exit

route interface github_in process issue_notify
 match event.issue exists
 match event.action eq "opened"
exit
