! Mixed shell + docker pipeline.
!
! `interface shell` declares a host-process execution environment;
! ShellRunner runs blocks under the daemon's user — DON'T use it for
! untrusted code. `interface docker` declares an isolated container
! environment. The orchestrator dispatches per-block.
!
!   $ prouter apply examples/06_shell_block.prc --db /tmp/o.db
!   $ echo '{}' > /tmp/event.json
!   $ prouter trigger process mixed input /tmp/event.json --db /tmp/o.db

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

interface shell host
exit

interface docker alpine
 image alpine:latest
exit

process mixed
 queue default
 no shutdown

 ! Step 1: shell block — runs as a local process
 block prepare
  interface shell host
  exec "sh -c 'echo \"{\\\"prepared\\\":true,\\\"by\\\":\\\"shell\\\"}\" > $PROUTER_OUTPUT_PATH'"
  timeout 10s
  enable
 exit

 ! Step 2: docker block — runs as a container
 block finalize
  interface docker alpine
  command "sh -c 'echo done-via-docker >&2; echo \"{\\\"ok\\\":true}\" > /prouter/output.json'"
  timeout 30s
  enable
 exit

 route prepare finalize
exit

route interface cli process mixed
exit
