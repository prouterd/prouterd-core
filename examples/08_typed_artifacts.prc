! Typed-artifact example: pass named files (not just JSON) between blocks.
!
! Pattern:
!   1. Producer block writes files into /prouter/artifacts/. For each file
!      it wants downstream blocks to consume it adds `produces <relpath>`.
!   2. Consumer block pulls via `input from <upstream_block>.<relpath>`.
!      The local name is derived from the basename minus its last extension
!      (`model.pkl` -> `model`). Runtime stages the file at
!      /prouter/inputs/<local_name> and exports PROUTER_INPUT_<UPCASE_NAME>.
!
! Failure modes (caught at runtime / validation):
!   - Producer didn't write a `produces` file → error_type "missing_artifact"
!   - Consumer references an undeclared artifact → `prouter check` rejects
!
!   $ prouter apply examples/08_typed_artifacts.prc --db /tmp/o.db
!   $ echo '{}' > /tmp/event.json
!   $ prouter trigger process inference input /tmp/event.json --db /tmp/o.db

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

process inference
 queue default
 no shutdown

 ! Producer: writes two named files into /prouter/artifacts/.
 block train
  interface docker alpine
  command `sh -c 'echo MODEL > /prouter/artifacts/model.pkl && echo {"acc":0.92} > /prouter/artifacts/metrics.json && echo {"trained":true} > /prouter/output.json'`
  produces model.pkl
  produces metrics.json
  timeout 60s
  enable
 exit

 ! Consumer: reads the named artifacts.
 block deploy
  interface docker alpine
  command `sh -c 'cat $PROUTER_INPUT_MODEL && cat $PROUTER_INPUT_METRICS && echo {"deployed":true} > /prouter/output.json'`
  input from train.model.pkl
  input from train.metrics.json
  timeout 30s
  enable
 exit

 route train deploy
exit

route interface cli process inference
exit
