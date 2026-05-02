! Branches on a runtime value: scorer outputs {"score": N}, and the
! match condition routes to notify_sales (high score) or notify_marketing
! (low score). The trace command shows these as "depends on runtime"
! because the score isn't known until scorer runs.
!
!   $ prouter apply examples/02_conditional_routing.prc --db /tmp/o.db
!   $ prouter trace event /dev/null --interface cli --db /tmp/o.db
!   $ prouter trigger process score_pipe input /dev/null --db /tmp/o.db

router demo
exit

queue default
 concurrency 4
 timeout 1m
exit

interface manual cli
 no shutdown
exit

process score_pipe
 queue default
 no shutdown

 block scorer
  type docker
   image alpine:latest
   command "sh -c 'echo \"{\\\"score\\\":85}\" > /prouter/output.json'"
  exit
  output lead.scored
  timeout 30s
  enable
 exit

 block notify_sales
  type docker
   image alpine:latest
   command "sh -c 'echo HIGH-VALUE >&2; echo \"{\\\"sent\\\":\\\"sales\\\"}\" > /prouter/output.json'"
  exit
  input lead.scored
  output sales.notified
  timeout 30s
  enable
 exit

 block notify_marketing
  type docker
   image alpine:latest
   command "sh -c 'echo NURTURE >&2; echo \"{\\\"sent\\\":\\\"marketing\\\"}\" > /prouter/output.json'"
  exit
  input lead.scored
  output marketing.notified
  timeout 30s
  enable
 exit

 route scorer notify_sales
  match lead.scored.score gt 70
 exit
 route scorer notify_marketing
  match lead.scored.score lte 70
 exit
exit

route interface cli process score_pipe
exit
