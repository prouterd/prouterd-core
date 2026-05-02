! Webhook interface with bearer authentication. Start the daemon, then
! POST events to /i/leads_in. Run executes asynchronously; the request
! returns a run_id within milliseconds.
!
!   $ export WEBHOOK_TOKEN=demo-token
!   $ prouter apply examples/04_webhook.prc --db /tmp/o.db
!   $ prouter serve --db /tmp/o.db --port 8089 &
!   $ curl -s -X POST http://127.0.0.1:8089/i/leads_in \
!       -H "Authorization: Bearer demo-token" \
!       -d '{"type":"lead.created","body":{"name":"Acme"}}'
!     {"run_id":"run_xxxxxxxx","status":"queued"}

router demo
exit

secret WEBHOOK_TOKEN
 source env WEBHOOK_TOKEN
exit

queue default
 concurrency 4
 timeout 1m
exit

interface webhook leads_in
 path /leads
 method POST
 auth bearer secret WEBHOOK_TOKEN
 no shutdown
exit

process pipeline
 queue default
 block extract
  image alpine:latest
  command "sh -c 'echo extracted >&2; echo \"{\\\"raw\\\":true}\" > /prouter/output.json'"
  timeout 30s
  input event.body
  output lead.raw
 exit
exit

route interface leads_in process pipeline
 match event.type eq "lead.created"
exit
