! Smallest pipeline that does anything: one block that echoes hello.
!
!   $ bundle exec ruby exe/prouter apply examples/01_hello_world.prc \
!       --db /tmp/prouterd.db
!   $ echo '{"name":"world"}' > /tmp/event.json
!   $ bundle exec ruby exe/prouter trigger process hello \
!       input /tmp/event.json --db /tmp/prouterd.db

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

process hello
 queue default
 block greet
  image alpine:latest
  command "sh -c 'NAME=$(cat $PROUTER_INPUT_PATH | sed -n \"s/.*\\\"name\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\"); echo \"hello, $NAME!\" >&2; echo \"{\\\"greeted\\\":\\\"$NAME\\\"}\" > /prouter/output.json'"
  timeout 30s
  input event
  output greeting
 exit
exit

route interface cli process hello
exit
