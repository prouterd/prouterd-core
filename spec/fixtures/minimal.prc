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

interface docker alpine
 image alpine:latest
exit

process pipeline
 queue default
 no shutdown

 block hello
  interface docker alpine
  command "echo hello"
  timeout 5s
  enable
 exit
exit

route interface cli process pipeline
exit
