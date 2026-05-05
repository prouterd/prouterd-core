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

 ! Step 1: shell block — runs as a local process. Stdout-as-JSON means
 ! we don't even have to redirect to $PROUTER_OUTPUT_PATH; the runner
 ! parses single-line JSON stdout into output_json automatically.
 block prepare
  interface shell host
  exec `echo '{"prepared":true,"by":"shell"}'`
  timeout 10s
  enable
 exit

 ! Step 2: docker block — runs as a container. Docker keeps the strict
 ! /prouter/output.json contract, so we still write the file (the
 ! container's filesystem is the contract surface).
 block finalize
  interface docker alpine
  command `sh -c "echo done-via-docker >&2; echo '{\"ok\":true}'"`
  timeout 30s
  enable
 exit

 route prepare finalize
exit

route interface cli process mixed
exit
