! Smallest pipeline that does anything: one shell block that greets the
! event payload by name. Demonstrates {{path}} templating into call-fields
! — the orchestrator substitutes `{{event.name}}` against the inbound
! event before handing the command to the shell runner. No JSON parsing,
! no JSON synthesis, no docker daemon — just stdlib.
!
!   $ prouter apply examples/01_hello_world.prc --db /tmp/prouterd.db
!   $ echo '{"name":"world"}' > /tmp/event.json
!   $ prouter trigger process hello input /tmp/event.json --db /tmp/prouterd.db

router demo
exit

interface manual cli
 no shutdown
exit

interface shell host
exit

process hello
 no shutdown

 block greet
  interface shell host
  exec "echo hello, {{event.name}}!"
 exit
exit

route interface cli process hello
exit
