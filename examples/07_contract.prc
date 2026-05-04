! Contract example: declare a JSON-output contract, attach it to a
! block, and let the runtime enforce it.
!
! Contract semantics:
!   1. `contract <name>` is a top-level section. Each `require <path>` /
!      `optional <path>` line declares a constraint. Lines for the same
!      path accumulate into one Requirement.
!   2. A block opts in via `contract <name>` inside its body.
!   3. After the runner writes /prouter/output.json, ContractValidator
!      checks every Requirement and applies the `on violation` policy:
!        fail   — run is marked failed, downstream blocks are skipped
!        retry  — reuses the block's retry policy as if it had crashed
!        warn   — log the violation, keep the run successful
!
! This example demos the success path. To see contract failure, change
! "score":85 to "score":150 in the command below — `score` will fail
! with "score must be <= 100" and `notify` will never run.
!
!   $ prouter apply examples/07_contract.prc --db /tmp/o.db
!   $ echo '{}' > /tmp/event.json
!   $ prouter trigger process scoring input /tmp/event.json --db /tmp/o.db

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

contract scored_v1
 require score type integer min 0 max 100
 require label type string in A,B,C,D,F
 optional notes type string max-length 200
 on violation fail
exit

process scoring
 queue default
 no shutdown

 block score
  interface docker alpine
  command "sh -c 'echo \"{\\\"score\\\":85,\\\"label\\\":\\\"A\\\"}\" > /prouter/output.json'"
  contract scored_v1
  timeout 30s
  enable
 exit

 block notify
  interface docker alpine
  command "sh -c 'echo notified-with={{score.score}}-{{score.label}} >&2; echo \"{\\\"notified\\\":true}\" > /prouter/output.json'"
  timeout 30s
  enable
 exit

 route score notify
exit

route interface cli process scoring
exit
