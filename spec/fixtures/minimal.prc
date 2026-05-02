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
  type docker
   image alpine:latest
   command "echo hello"
  exit
  output result
  timeout 5s
  enable
 exit
exit

route interface cli process pipeline
exit
