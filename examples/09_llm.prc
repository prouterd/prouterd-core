! LLM in the loop: an inbound webhook receives a ticket-shaped event;
! the `summarize` block hits Anthropic's /v1/messages with the ticket
! body templated into the prompt; the `notify` block prints the
! one-sentence summary that came back.
!
!   $ export CLAUDE_KEY=...your-anthropic-api-key...
!   $ prouter apply examples/09_llm.prc --db /tmp/prouterd.db
!   $ prouter trigger process triage \
!       input <(echo '{"body":"User cannot reset password — keeps getting CAPTCHA loop"}') \
!       --db /tmp/prouterd.db

router demo
exit

secret CLAUDE_KEY
 source env CLAUDE_KEY
exit

interface manual cli
 no shutdown
exit

interface shell host
exit

interface llm claude
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

process triage
 no shutdown

 block summarize
  interface llm claude
  system "You summarize incoming support tickets in one terse sentence."
  prompt "{{event.body}}"
  max-tokens 256
  timeout 30s
  enable
 exit

 ! `{{summarize.text}}` reads the previous block's output via templating
 ! — no JSON parsing in shell, no sed pipelines, no docker.
 block notify
  interface shell host
  exec "echo summary: {{summarize.text}}"
  timeout 10s
  enable
 exit

 route summarize notify
exit

route interface cli process triage
exit
