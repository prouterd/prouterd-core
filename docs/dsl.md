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

interface cron daily_report     ! bundled in Docker image
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
interface shell host                          ! bundled in Docker image
 cwd /opt/blocks
 env API_BASE https://api.example.com
exit

interface http jira                           ! bundled in Docker image
 base-url https://acme.atlassian.net/rest/api/3
 auth bearer secret JIRA_TOKEN
exit

interface llm claude                          ! bundled in Docker image
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

interface llm researcher                      ! subprocess provider
 provider codex_cli                            ! or claude_cli
 model gpt-5-codex
 home /var/lib/prouterd/codex                  ! HOME for subscription state
 sandbox read-only                             ! `-s <mode>`
 env JIRA_URL "https://example.atlassian.net"  ! static var
 env-forward GITLAB_TOKEN                      ! pass through if set
 env-forward PATH                              ! whitelist daemon PATH
 secret SENTRY_AUTH                            ! resolved → env SENTRY_AUTH
exit                                           ! declaring any env/env-forward/
                                                ! secret flips the spawn into
                                                ! `unsetenv_others: true` mode

interface docker scorer                       ! bundled; mount Docker socket to use
 image registry.local/blocks/score:v2
 memory 512m
exit

interface postgres warehouse                  ! bundled in Docker image
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

## Subprocess LLM blocks

`interface llm` with `provider codex_cli` or `provider claude_cli`
spawns the local CLI binary instead of speaking HTTP. The block can
tune the spawn with these call-fields:

```prc
block investigate
 interface llm researcher
 prompt "Triage incident {{event.id}} in the repo at {{event.repo_path}}"
 system "you are terse"
 cwd "{{event.repo_path}}"      ! chdir for the agent's workspace view
 reasoning-effort low           ! codex_cli only; -c model_reasoning_effort=low
 stream on                      ! tee JSONL events into run_logs as they arrive
exit
```

- `cwd <path>` — chdirs the spawn. Both subprocess providers
  inherit it; HTTP providers ignore. `invalid_cwd` at runtime if
  the directory does not exist.
- `reasoning-effort <low|medium|high|xhigh>` — codex_cli only;
  appended as `-c model_reasoning_effort=<level>`. Silently ignored
  for `claude_cli`.
- `stream on` — invokes the CLI in JSONL streaming mode
  (codex_cli is already JSONL; claude_cli flips to
  `--output-format stream-json --verbose`) and writes each line
  into the per-step `run_logs` as it arrives. `prouter logs
  <run_uid> --follow` then sees agent progress in real time.
  Final aggregated `output_json` is unchanged for downstream
  blocks regardless of this setting.

## Parallel: declare a fan-out group inline

`parallel <name>` declares a group of member blocks inline plus a
synthesized barrier that aggregates their outputs. Members run
concurrently. Routing into the group name fans out to every member
as a single edge — one external route triggers the whole group,
one barrier output flows downstream.

```prc
process incident
 block upstream
  interface http monitor
  method GET
  path "/health/{{event.id}}"
 exit

 parallel after_health
  join-strategy all-best-effort     ! all-required | all-best-effort | merge-children
  block check_cpu
   interface http monitor
   method GET
   path "/cpu/{{event.id}}"
  exit
  block check_disk
   interface http monitor
   method GET
   path "/disk/{{event.id}}"
  exit
  block check_logs
   interface shell host
   exec "tail-recent-logs.sh {{event.id}}"
  exit
 exit

 block summarize
  interface llm claude
  prompt "{{after_health.members.check_cpu}} {{after_health.members.check_disk}}"
 exit

 route upstream after_health     match upstream.ok eq true
 route after_health summarize
exit
```

A single `route upstream after_health` triggers every member of the
group; the `match` condition applies once to the fan-out rather
than being copy-pasted across N per-member routes. The barrier
fires after the members finish per the chosen `join-strategy` and
flows into `summarize` via the standard barrier→downstream route.

## Merge: barrier over existing sibling blocks

`merge <name>` aggregates the outputs of existing sibling blocks
into a single barrier. Differs from `parallel <name>` in that the
members are referenced (`from a, b, c`), not declared inline —
useful when the members already participate in longer chains.

```prc
process triage
 block fetch_jira
  interface http jira
  method GET
  path "/issue/{{event.key}}"
 exit
 block fetch_sentry
  interface http sentry
  method GET
  path "/issues/{{event.key}}/"
 exit
 block fetch_logs
  interface shell host
  exec "tail-logs.sh {{event.key}}"
 exit

 merge evidence
  from fetch_jira, fetch_sentry, fetch_logs
  strategy all-best-effort           ! any | all-required | all-best-effort
 exit

 block summarize
  interface llm claude
  prompt "{{evidence.members.fetch_jira.fields.summary}}"
 exit

 route evidence summarize
exit
```

Strategies:

| Strategy          | Readiness                                  | Failure handling                                   | Barrier output shape                                                  |
| ----------------- | ------------------------------------------ | -------------------------------------------------- | --------------------------------------------------------------------- |
| `any`             | first member's route fires                 | failure on one member doesn't block the survivors  | `{winner, output, join_strategy: "any"}`                              |
| `all-required`    | every member is in a terminal state        | any member failure aborts the run (on_failure=stop)| `{members, succeeded, failed, join_strategy: "all-required"}`         |
| `all-best-effort` | every member is in a terminal state        | never fails the run; failures listed under `failed`| `{members, succeeded, failed, join_strategy: "all-best-effort"}`      |

AND-style strategies (`all-required` / `all-best-effort`) hold
the barrier in the scheduler until every named member has finished,
even if members finish at different BFS levels. `parallel` keeps
its eager-enqueue semantics because its members are guaranteed
same-level siblings.

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
