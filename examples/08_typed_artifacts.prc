! Typed-artifact example: pass named files (not just JSON) between blocks.
!
! How it works:
!   1. The producer writes files into /prouter/artifacts/. For each file it
!      wants downstream blocks to consume, it adds `produces <relpath>` to
!      its block — declaring "this file MUST exist after I run, and it has
!      a stable name other blocks can refer to".
!   2. A consumer pulls a named artifact via
!        `input from <upstream_block>.<relpath>`.
!      The local name is derived from the basename minus its last extension
!      (`model.pkl` -> `model`); the runtime stages the file at
!      /prouter/inputs/<local_name> and exports `PROUTER_INPUT_<UPCASE_NAME>`
!      pointing at it. If two inputs would derive the same local name,
!      `prouter check` errors at validation time — rename the file in the
!      upstream block's `produces` to disambiguate.
!   3. The existing JSON event flow (input <ctx.path> / output <ctx.path>)
!      keeps working alongside — typed artifacts are additive.
!
! Failure modes:
!   - If the producer doesn't write a file it declared via `produces`, the
!     block fails with error_type = "missing_artifact" and downstream is
!     skipped (same retry/on-failure semantics as any block error).
!   - If the consumer references an artifact the upstream doesn't declare,
!     `prouter check` fails at config-validation time, before commit.
!
!   $ prouter apply examples/08_typed_artifacts.prc --db /tmp/o.db
!   $ echo '{}' > /tmp/event.json
!   $ prouter trigger process inference input /tmp/event.json --db /tmp/o.db
!   $ prouter exec "show runs" --db /tmp/o.db

router demo
exit

queue default
 concurrency 1
 timeout 1m
exit

interface manual cli
 no shutdown
exit

process inference
 queue default
 no shutdown

 ! Producer: writes two named files into /prouter/artifacts/.
 ! In a real ML pipeline this is your trainer or feature-builder.
 block train
  type docker
   image alpine:latest
   command "sh -c 'echo MODEL > /prouter/artifacts/model.pkl && echo {\\\"acc\\\":0.92} > /prouter/artifacts/metrics.json && echo {\\\"trained\\\":true} > /prouter/output.json'"
  exit
  produces model.pkl
  produces metrics.json
  timeout 60s
  enable
 exit

 ! Consumer: reads the named artifacts plus the JSON event flow.
 block deploy
  type docker
   image alpine:latest
   command "sh -c 'cat $PROUTER_INPUT_MODEL && cat $PROUTER_INPUT_METRICS && echo {\\\"deployed\\\":true} > /prouter/output.json'"
  exit
  input from train.model.pkl
  input from train.metrics.json
  timeout 30s
  enable
 exit

 route train deploy
exit

route interface cli process inference
exit
