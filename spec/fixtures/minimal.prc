router demo
 version 1
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

process pipeline
 queue default
 no shutdown

 block hello
  image alpine:latest
  command "echo hello"
  timeout 5s
  output result
 exit
exit

route interface cli process pipeline
exit
