! Smallest pipeline that does anything: one block that echoes hello.
!
!   $ prouter apply examples/01_hello_world.prc --db /tmp/prouterd.db
!   $ echo '{"name":"world"}' > /tmp/event.json
!   $ prouter trigger process hello input /tmp/event.json --db /tmp/prouterd.db

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

interface docker alpine
 image alpine:latest
exit

process hello
 queue default
 no shutdown

 block greet
  interface docker alpine
  command "sh -c 'NAME=$(cat $PROUTER_INPUT_PATH | sed -n \"s/.*\\\"name\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\"); echo \"hello, $NAME!\" >&2; echo \"{\\\"greeted\\\":\\\"$NAME\\\"}\" > /prouter/output.json'"
  timeout 30s
  enable
 exit
exit

route interface cli process hello
exit
