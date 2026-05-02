! Cron interface. The scheduler thread inside `prouter serve` fires the
! pipeline every minute. event.fired_at carries the trigger timestamp;
! event.interface names the originating cron.
!
!   $ prouter apply examples/05_cron.prc --db /tmp/o.db
!   $ prouter serve --db /tmp/o.db --port 8090
!   # wait ~1 minute, then in another terminal:
!   $ prouter exec "show runs" --db /tmp/o.db
!     # one run per minute that passed

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface cron every_minute
 schedule "* * * * *"
 timezone "UTC"
 no shutdown
exit

process tick
 queue default
 block log_tick
  image alpine:latest
  command "sh -c 'echo TICK at $(date -u +%FT%TZ) >&2; echo \"{\\\"ok\\\":true}\" > /prouter/output.json'"
  timeout 30s
  output result
 exit
exit

route interface every_minute process tick
exit
