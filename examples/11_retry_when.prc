! Smart retry policy. Only retry on transient HTTP/llm errors. Do NOT
! retry when our own input was malformed (invalid_call), since retrying
! the same bad payload won't help. The block also templates `iteration`
! and `previous.error_type` so a future LLM-based caller could feed the
! prior failure back into its prompt.
!
!   $ prouter apply examples/11_retry_when.prc --db /tmp/prouterd.db
!   $ prouter trigger process recover input /dev/null --db /tmp/prouterd.db

router demo
exit

policy transient_only
 retry attempts 3
 retry backoff exponential
 retry initial-delay 500ms
 retry max-delay 5s
 retry when error_type in "timeout","http_status","http_error","llm_error"
exit

interface manual cli
 no shutdown
exit

interface docker alpine
 image alpine:latest
exit

process recover
 no shutdown

 block fetch
  interface docker alpine
  retry policy transient_only
  ! On attempt 1 `{{previous.error_type}}` resolves to the empty string;
  ! on later attempts it carries the prior failure's error_type, so the
  ! block can adapt its behaviour or include richer context in its log.
  command "sh -c 'echo attempt={{iteration}} last={{previous.error_type}} >&2; exit 1'"
  timeout 30s
  enable
 exit
exit

route interface cli process recover
exit
