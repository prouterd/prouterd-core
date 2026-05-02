! A flaky block + retry policy. The block always fails (exit 1) so the
! orchestrator burns through all 3 attempts with exponential backoff
! between them, then marks the run failed. The dead-letter view lists it.
!
!   $ prouter apply examples/03_retries.prc --db /tmp/o.db
!   $ prouter trigger process flaky_pipe input /dev/null --db /tmp/o.db
!   $ prouter exec "show dead-letter" --db /tmp/o.db
!   $ prouter exec "show logs run <uid>" --db /tmp/o.db
!     # — three attempts visible, two "retrying" system lines

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

policy r3_exp
 retry attempts 3
 retry backoff exponential
 retry initial-delay 100ms
 retry max-delay 1s
exit

process flaky_pipe
 queue default
 block flaky
  image alpine:latest
  command "sh -c 'echo always-fails >&2; exit 1'"
  timeout 30s
  retry policy r3_exp
  output result
 exit
exit

route interface cli process flaky_pipe
exit
