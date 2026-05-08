# prouterd

**Pipelines as config, not code.**

A single-binary orchestrator for ops automation: webhooks, cron,
LLM calls, HTTP, shell, docker — all declared in a `.prc` text file
committed to git. No Python, no YAML, no SaaS dashboard.

> Like Airflow, without the Python.
>
> Like Argo Workflows, without the Kubernetes.
>
> Like n8n, with config that survives a code review.

## Read this and tell me what it does

```prc
secret JIRA_TOKEN
 source env JIRA_TOKEN
exit

interface webhook jira_in
 path /jira-trigger
 method POST
 auth bearer secret WEBHOOK_TOKEN
exit

interface http jira
 base-url https://acme.atlassian.net/rest/api/3
 auth bearer secret JIRA_TOKEN
exit

interface llm claude
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

process triage
 block fetch
  interface http jira
  method GET
  path "/issue/{{event.issue.key}}"
 exit
 block summarize
  interface llm claude
  system "Summarize the ticket in one sentence."
  prompt "{{fetch.fields.summary}}\n\n{{fetch.fields.description}}"
 exit
 block comment
  interface http jira
  method POST
  path "/issue/{{event.issue.key}}/comment"
  body-json `{"body":{{summarize.text}}}`
 exit
 route fetch summarize
 route summarize comment
exit

route interface jira_in process triage
 match event.issue.fields.status.name eq "Needs Triage"
exit
```

You just read a 4-block pipeline that webhooks Jira → fetches the
ticket → summarizes via Claude → posts a comment back. **In 35 lines.
Zero code.** Try doing that with the same readability in Airflow,
Temporal, Argo, or n8n.

## Why a text DSL beats every alternative

| Tool                    | Source form              | Readable in `git diff` | Standalone | Operator can edit without engineering? |
| ----------------------- | ------------------------ | ---------------------- | ---------- | -------------------------------------- |
| Airflow / Prefect / Dagster | Python                | only by Python devs    | needs DB / scheduler | no                          |
| Temporal / Cadence      | Go / Java / TS           | only by code devs      | needs cluster | no                                   |
| LangGraph / LlamaIndex  | Python / TS              | only by code devs      | needs runtime | no                                   |
| Zapier / Make           | proprietary UI state     | **no** — lives in their DB | SaaS-only | yes, but they own your config         |
| n8n                     | JSON (UI-managed)        | technically yes, practically no | self-host yes | sort of, via their UI       |
| GitHub Actions          | YAML                     | yes                    | external (lives at GitHub) | yes                            |
| Argo Workflows / Tekton | YAML + jinja + kustomize | yes, behind templating | k8s-bound | DevOps engineer required              |
| AWS Step Functions      | JSON ASL                 | yes                    | AWS-only   | no                                    |
| **prouterd**            | **text DSL (`.prc`)**    | **yes, instantly**     | **single binary, SQLite** | **yes — config IS the truth** |

The whole quadrant of *"text DSL + standalone + readable"* was empty.
That's the niche. That's what prouterd is.

## 30-second demo

```bash
gem install prouterd
echo '{"name":"world"}' > /tmp/event.json

cat > /tmp/hello.prc <<'EOF'
router demo
exit
interface manual cli
 no shutdown
exit
interface shell host
exit
process hello
 block greet
  interface shell host
  exec "echo hello, {{event.name}}!"
 exit
exit
route interface cli process hello
exit
EOF

prouter apply /tmp/hello.prc --db /tmp/p.db
prouter trigger process hello input /tmp/event.json --db /tmp/p.db --runner shell
# → Run run_xxx: success
#     greet  success  3ms     [stdout: hello, world!]
```

That's the whole loop: declare → apply → trigger → inspect. The same
flow runs inside the daemon (`prouterd`) when triggers come from
webhooks or cron instead of the CLI.

## Operator shell

Configuration is text, but operators don't have to edit text. The
shell drops you into a router-style mode stack — `configure terminal`,
`commit`, `abort`, `rollback`, `show running-config`. Familiar to
anyone who's ever touched a router CLI.

```text
sales-prouter-01# show running-config
sales-prouter-01# configure terminal
sales-prouter-01(config)# process triage
sales-prouter-01(config-process)# block summarize
sales-prouter-01(config-block)# max-tokens 512
sales-prouter-01(config-process)# commit
Commit complete.
sales-prouter-01# show config commits
ID  CHECKSUM       AUTHOR  MESSAGE
12  sha256:c4f2…   carol   raise summarize budget
11  sha256:91003…  alice   initial triage pipeline
```

Every commit is a versioned snapshot. `rollback commit 11` restores
the previous version. `diff file.prc running-config` shows what would
change before you apply.

## Built-in interfaces

The base install runs on Ruby stdlib — no Docker daemon required.
Heavier callers are `gem install` away.

| `interface …`        | Does what                                       | Needs                    |
| -------------------- | ----------------------------------------------- | ------------------------ |
| `shell <name>`       | Host process via `Open3`                        | _(default)_              |
| `http <name>`        | `Net::HTTP` GET/POST/… JSON APIs                | _(default)_              |
| `llm <name>`         | Anthropic / OpenAI HTTP, or Codex / Claude CLI  | _(default)_              |
| `webhook <name>`     | Inbound HTTPS endpoint with bearer auth         | _(default)_              |
| `manual <name>`      | Inbound entry for `prouter trigger`             | _(default)_              |
| `local_repo <name>`  | Read commits, files, grep in whitelisted git repos | `git` on PATH         |
| `docker <name>`      | OCI container with image / memory / cpu         | `gem install docker-api` |
| `postgres <name>`    | SQL with `$1..$N` bind params                   | `gem install pg`         |
| `cron <name>`        | Inbound cron schedule                           | `gem install fugit`      |

Adding your own type is one plugin file + one caller class — no edits
to parser/validator/renderer/CLI. See [CLAUDE.md](CLAUDE.md) for the
worked recipe.

## What you get with it

- **Versioned config history.** Every `apply` is a git-style commit.
  `show config commits`, `rollback`, `diff file running-config`,
  `prouter validate <file> --against running` for semantic dry-run.
- **Smart retries with reflection.** Backoff (fixed/linear/exponential)
  plus `retry when` predicates that fire on failure metadata OR output
  fields (`retry when output.verify eq "fail"`). `retry feedback
  output.notes into feedback` carries notes forward as
  `{{previous.feedback}}` — reflection loops, no boilerplate.
- **Cost-aware budgets.** A top-level `prices <provider>` table
  feeds a per-run `cost_usd` accumulator. Block-level `max-cost-usd`
  fails the block if it crosses the cap; policy-level `retry stop-on
  run.cost_usd gt N` breaks a runaway retry loop on cost regardless
  of attempts left.
- **Replay.** Re-run a finished run with the same input + same config
  commit, or start mid-pipeline from a chosen block.
- **Pause + resume.** A `pause "<reason>"` block halts the run with
  `status="paused"`; `prouter resume <run> --value <json>` injects an
  output and continues. Foundation for human-in-the-loop.
- **Parallel groups.** `parallel evidence ... block fetch_jira ...
  block fetch_slack ... exit` runs siblings concurrently with
  `all-required` or `all-best-effort` join semantics — routing flows
  in/out of the group as if it were one block.
- **Fan-out with `map` / `dedupe` / `rate-limit`.** `fan-out from
  issues into analyze_ticket` opens a sub-section: project upstream
  fields onto child events, skip dupes inside a window keyed by
  `thread_id`, space child enqueue via the durable jobs queue.
  Lineage queryable via `parent_run_id`.
- **Per-entity scoping.** `thread-id "{{event.ticket}}"` on a process
  pins each run to a stable id; list / replay / cancel queries filter
  by it.
- **LLM blocks, native.** Anthropic + OpenAI HTTP plus Codex / Claude
  CLI providers (subscription pricing via subprocess + JSONL).
  Multi-turn tool use with `agentic on` + `allowed-tools` +
  `tool-call-limit`. Per-run token usage aggregated into
  `runs.tokens_in/out` and surfaced in `/v1`.
- **Prompts in their own files.** `system file "prompts/x.system.md"`
  + `prompt file "prompts/x.user.md.tmpl"` keeps prose out of the
  `.prc`; `vars { evidence "{{event.body.evidence}}" }` exposes local
  names inside the prompt.
- **Conditional skip.** `skip-when event.flag eq ""` short-circuits a
  block with `status="skipped"`, downstream still routes through.
- **Local-repo access.** `interface local_repo` — whitelisted,
  sandboxed read-only git for code-aware pipelines. No raw shell.
  Optional `auto-pull <duration>` keeps checkouts fresh from the
  daemon, no external cron required.
- **`shell_tool <name>` sugar.** Collapses the
  `interface shell` + `tool` + `implementation` triplet into one
  declaration for shell-script integrations. Pure parser-time
  expansion, no new runtime.
- **Output contracts.** Declare expected JSON shape, validate at
  runtime, fail / retry / warn on violation.
- **Typed artifacts.** `produces model.pkl`, `input from
  train.model.pkl`. Files between blocks, not just JSON.
- **Webhook ingestion.** `interface webhook` with bearer auth, rate
  limits, body-size cap, async dispatch.
- **`/metrics`** Prometheus, **`/v1/events`** WebSocket live tail.
- **Graceful shutdown.** Drains in-flight runs before stopping.

## Install

```bash
gem install prouterd
```

Requires Ruby ≥ 3.2 + `libsqlite3-dev`. SQLite is the only hard runtime
dep (plus rack + puma for the daemon). Docker / Postgres / cron features
are opt-in (table above).

Or as a container:

```bash
docker run --rm -p 127.0.0.1:8080:8080 \
  -v prouterd-data:/data \
  -e PROUTERD_ADMIN_TOKEN=demo \
  ghcr.io/prouterd/prouterd:latest
```

## Documentation

- [`docs/dsl.md`](docs/dsl.md) — full `.prc` reference
- [`docs/cli.md`](docs/cli.md) — `prouter` + `prouterd` commands, HTTP endpoints
- [`docs/production.md`](docs/production.md) — env vars, secrets, deployment
- [`CLAUDE.md`](CLAUDE.md) — internals + extension recipes
- [`examples/`](examples/) — twelve runnable `.prc` files, including
  end-to-end pipelines:
  - [01_hello_world](examples/01_hello_world.prc) — minimal shell
  - [02_conditional_routing](examples/02_conditional_routing.prc) — `match` on routes
  - [11_retry_when](examples/11_retry_when.prc) — smart retries
  - [10_tg_github](examples/10_tg_github/) — GitHub → Telegram
  - [12_jira_debug](examples/12_jira_debug/) — webhook → http → postgres → llm → http

## Status

Production-ready core. 778 specs, 0 failures. End-to-end smoke-tested
against real Docker, Puma, cron, and shell exec. Web console
(`prouterd-web`) ships separately and talks to the daemon over `/v1`
HTTP + `/v1/events` WS.

Out of scope for v0.1 (the plugin interfaces are ready — write a plugin
file and a caller class, no core edits): KubernetesCaller, S3
ArtifactStore, Vault / AWS Secrets Manager, RBAC / mTLS / OIDC,
idempotency keys. Storage is SQLite, by design — single binary, no
external DB dependency.

See [CHANGELOG.md](CHANGELOG.md) for the per-version breakdown
(38 phases shipped).

## License

MIT.
