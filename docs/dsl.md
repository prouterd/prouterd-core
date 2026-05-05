# DSL reference

`.prc` files are line-oriented router-style config. Comments start with
`!` or `#`. Indentation is cosmetic — sections are bounded by `exit`.
Two string forms:

- `"..."` double-quoted: `\n` / `\t` / `\r` / `\\` / `\"` escapes
- `` `...` `` backtick raw: every byte literal, no escape processing

## Top-level sections

```prc
router demo                     ! one router per file
 hostname my-router-01
 version 1
exit

secret API_TOKEN                ! never appears in rendered config
 source env API_TOKEN           ! reads $API_TOKEN from daemon env
exit

secret PG_DSN
 source file /run/secrets/pg    ! Docker / Kubernetes secret volumes
exit

policy retry_standard           ! reusable retry policy
 retry attempts 3
 retry backoff exponential      ! fixed | linear | exponential
 retry initial-delay 5s
 retry max-delay 2m
 retry when error_type in "timeout","http_status"   ! optional gate
exit

queue default                   ! parallelism + timeout per process
 concurrency 10
 timeout 10m
exit

contract scored_v1              ! optional output validation
 require score type integer min 0 max 100
 require label type string in A,B,C,D,F
 optional notes type string max-length 200
 on violation fail              ! fail | retry | warn
exit
```

## Inbound interfaces (trigger pipelines)

```prc
interface webhook leads_in
 path /leads
 method POST
 auth bearer secret WEBHOOK_TOKEN
 no shutdown
exit

interface cron daily_report     ! requires gem install fugit
 schedule "0 9 * * *"
 timezone "Europe/Berlin"
 no shutdown
exit

interface manual cli            ! triggered via prouter trigger / /v1
 no shutdown
exit
```

## Outbound interfaces (called by blocks)

```prc
interface shell host                          ! default install
 cwd /opt/blocks
 env API_BASE https://api.example.com
exit

interface http jira                           ! default install
 base-url https://acme.atlassian.net/rest/api/3
 auth bearer secret JIRA_TOKEN
exit

interface llm claude                          ! default install
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

interface docker scorer                       ! gem install docker-api
 image registry.local/blocks/score:v2
 memory 512m
exit

interface postgres warehouse                  ! gem install pg
 dsn "{{secret.PG_DSN}}"
 statement-timeout 5000
exit
```

## Process + blocks + routes

```prc
process lead_pipeline
 description "Lead enrichment + sales notification"
 queue default
 no shutdown

 block extract
  interface shell host
  exec "ruby /opt/blocks/extract.rb"
  timeout 30s
  enable
 exit

 block score
  interface docker scorer                     ! call-fields override iface
  command `echo '{"score":85,"label":"A"}'`   ! backtick = raw string
  contract scored_v1
  retry policy retry_standard
  timeout 20s
  enable
 exit

 block notify_sales
  interface http jira
  method POST
  path "/issue/{{event.issue.key}}/comment"
  body-json `{"body":"score: {{score.score}}"}`
  secret JIRA_TOKEN
  timeout 15s
 exit

 ! short-form route — no conditions
 route extract score

 ! long-form route — match conditions
 route score notify_sales
  match score.score gt 70
 exit
exit

! global route: wire inbound to process
route interface leads_in process lead_pipeline
 match event.type eq "lead.created"
exit
```

## Templating

`{{path.to.value}}` is substituted in call-fields right before dispatch.
Sources, in priority:

| Path                    | What it is                                          |
| ----------------------- | --------------------------------------------------- |
| `{{event.X}}`           | inbound event payload                               |
| `{{<block>.<field>}}`   | upstream block's `output_json[<field>]`             |
| `{{secret.<NAME>}}`     | resolved value of `secret <NAME>`                   |
| `{{iteration}}`         | 1-indexed retry attempt number                      |
| `{{previous.error_type}}` | prior attempt's failure metadata (on retry)       |

Arrays index by number: `{{event.tags.0}}`. Missing paths render as
empty string.

## Match operators

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `exists`, `in`. Multiple `match`
lines within one route AND together. There is no OR — split into two
routes.

## Block output rules

For shell + docker blocks, exit 0 + output discovered in this order:

1. `/prouter/output.json` exists and parses → use it
2. file exists but empty → `output_json = {}`
3. file missing + stdout parses as JSON Hash/Array → use stdout
4. otherwise → `{}`

Malformed JSON in an explicit file is `invalid_output`. A non-zero exit
is always `non_zero_exit`. Net effect: trivial blocks can drop
`> /prouter/output.json` and just `echo '{"score":85}'`.

For http / llm / postgres blocks output is plugin-shaped (see
[interfaces section in README](../README.md#outbound-interfaces)).

## Two ways data flows between blocks

| Use for                              | Declare with                                | Reaches the block via                           |
| ------------------------------------ | ------------------------------------------- | ----------------------------------------------- |
| JSON values (fields, numbers)        | `{{<upstream>.<field>}}` in call-args       | templated call-fields + `/prouter/input.json`   |
| Files (model.pkl, parquet, blobs)    | `produces <relpath>` / `input from <b>.<r>` | `/prouter/inputs/<derived_name>`                |

Each block's `output_json` auto-stores at `context[block.name]`. No
explicit `input` / `output` directive on blocks — outputs are auto-keyed,
inputs flow via templating.

## Container/process contract (docker, shell)

| Path                       | Direction | Purpose                                                 |
| -------------------------- | --------- | ------------------------------------------------------- |
| `/prouter/input.json`      | read      | run_id, process, block, full context                    |
| `/prouter/output.json`     | write     | block's JSON result (optional — see rules above)        |
| `/prouter/artifacts/`      | write     | files to archive (consumable downstream via `produces`) |
| `/prouter/inputs/<name>`   | read      | staged artifact from upstream                           |

Environment: `PROUTER_RUN_ID`, `PROUTER_PROCESS_NAME`, `PROUTER_BLOCK_NAME`,
`PROUTER_ATTEMPT`, `PROUTER_INPUT_PATH`, `PROUTER_OUTPUT_PATH`,
`PROUTER_ARTIFACTS_DIR`, `PROUTER_INPUT_<NAME>` per staged input, plus
every secret declared on the block.
