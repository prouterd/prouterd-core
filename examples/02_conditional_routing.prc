! Branches on a runtime value: scorer outputs {"score": N}, and the
! match condition routes to notify_sales (high score) or notify_marketing
! (low score). Static routing analysis via POST /v1/trace reports these
! as "depends on runtime" because the score isn't known until scorer runs.
!
! Demonstrates: backtick raw strings (no DSL escaping), stdout-as-JSON
! (ShellRunner parses single-line JSON stdout into output_json), and
! cross-block templating (`{{scorer.score}}`).
!
!   $ prouter apply examples/02_conditional_routing.prc --db /tmp/o.db
!   $ prouter trigger process score_pipe input /dev/null --db /tmp/o.db --runner shell

router demo
exit

queue default
 concurrency 4
 timeout 1m
exit

interface manual cli
 no shutdown
exit

interface shell host
exit

process score_pipe
 queue default
 no shutdown

 block scorer
  interface shell host
  exec `echo '{"score":85}'`
  timeout 30s
  enable
 exit

 block notify_sales
  interface shell host
  exec "echo HIGH-VALUE: score {{scorer.score}}"
  timeout 30s
  enable
 exit

 block notify_marketing
  interface shell host
  exec "echo NURTURE: score {{scorer.score}}"
  timeout 30s
  enable
 exit

 route scorer notify_sales
  match scorer.score gt 70
 exit
 route scorer notify_marketing
  match scorer.score lte 70
 exit
exit

route interface cli process score_pipe
exit
