! Lead processing pipeline (canonical example from the spec)
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
  image registry.local/blocks/extract-lead:v1
  timeout 30s
  input event.body
  output lead.raw
 exit

 block enrich
  image registry.local/blocks/enrich-lead:v3
  timeout 120s
  retry policy retry_standard
  secret CLEARBIT_API_KEY
  input lead.raw
  output lead.enriched
 exit

 block score
  image registry.local/blocks/score-lead:v2
  timeout 20s
  input lead.enriched
  output lead.scored
 exit

 block notify_sales
  image registry.local/blocks/notify-sales:v1
  timeout 15s
  input lead.scored
  output notification.result
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
