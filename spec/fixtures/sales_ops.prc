! Lead processing pipeline (canonical example from the spec, Phase 12 form)
router sales_ops
 version 1
 hostname prouter-01
exit

secret WEBHOOK_TOKEN
 source env WEBHOOK_TOKEN
exit

secret CLEARBIT_API_KEY
 source env CLEARBIT_API_KEY
exit

policy retry_standard
 retry attempts 3
 retry backoff exponential
 retry initial-delay 5s
 retry max-delay 2m
exit

queue default
 concurrency 10
 timeout 10m
exit

interface webhook leads_in
 path /leads
 method POST
 auth bearer secret WEBHOOK_TOKEN
 no shutdown
exit

process lead_pipeline
 description "Lead enrichment and sales notification"
 queue default
 no shutdown

 block extract
  type docker
   image registry.local/blocks/extract-lead:v1
  exit
  input event.body
  output lead.raw
  timeout 30s
  enable
 exit

 block enrich
  type docker
   image registry.local/blocks/enrich-lead:v3
  exit
  input lead.raw
  output lead.enriched
  timeout 120s
  retry retry_standard
  secret CLEARBIT_API_KEY
  enable
 exit

 block score
  type docker
   image registry.local/blocks/score-lead:v2
  exit
  input lead.enriched
  output lead.scored
  timeout 20s
  enable
 exit

 block notify_sales
  type docker
   image registry.local/blocks/notify-sales:v1
  exit
  input lead.scored
  output notification.result
  timeout 15s
  enable
 exit

 route extract enrich
 route enrich score

 route score notify_sales
  match lead.scored.score gt 70
 exit
exit

route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
