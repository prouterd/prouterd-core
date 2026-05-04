! type-shell example: a block that runs a local script via the
! ShellRunner instead of a Docker container. ShellRunner is faster for
! dev / iteration and works without docker-api, but the block runs under
! the daemon's user with the daemon's filesystem — DON'T use it for
! untrusted code.
!
! Mixed pipelines (some shell, some docker) work transparently — the
! orchestrator dispatches per-block based on `type`.
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

process mixed
 queue default
 no shutdown

 ! Step 1: shell block — runs as a local process
 block prepare
  type shell
   exec "sh -c 'echo \"{\\\"prepared\\\":true,\\\"by\\\":\\\"shell\\\"}\" > $PROUTER_OUTPUT_PATH'"
  exit
  input event
  output prep.result
  timeout 10s
  enable
 exit

 ! Step 2: docker block — runs as a container
 block finalize
  type docker
   image alpine:latest
   command "sh -c 'echo done-via-docker >&2; echo \"{\\\"ok\\\":true}\" > /prouter/output.json'"
  exit
  input prep.result
  output final.result
  timeout 30s
  enable
 exit

 route prepare finalize
exit

route interface cli process mixed
exit
