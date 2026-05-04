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

interface docker extractor
 image registry.local/blocks/extract-lead:v1
exit

interface docker enricher
 image registry.local/blocks/enrich-lead:v3
exit

interface docker scorer
 image registry.local/blocks/score-lead:v2
exit

interface docker notifier
 image registry.local/blocks/notify-sales:v1
exit

process lead_pipeline
 description "Lead enrichment and sales notification"
 queue default
 no shutdown

 block extract
  interface docker extractor
  timeout 30s
  enable
 exit

 block enrich
  interface docker enricher
  timeout 120s
  retry retry_standard
  secret CLEARBIT_API_KEY
  enable
 exit

 block score
  interface docker scorer
  timeout 20s
  enable
 exit

 block notify_sales
  interface docker notifier
  timeout 15s
  enable
 exit

 route extract enrich
 route enrich score

 route score notify_sales
  match score.score gt 70
 exit
exit

route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
