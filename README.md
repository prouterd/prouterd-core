# prouterd

**Process workflows as text, not code.**

> Like Airflow, without the Python.
>
> Like Argo Workflows, without the Kubernetes.
>
> Like n8n, but the config is **readable** — not a 5KB JSON blob hidden inside a database.

A self-hosted orchestrator where every workflow is a `.prc` text file
you commit to git. No Python decorators, no YAML soup, no JSON
state-machine, no SaaS dashboard hiding the truth. The config IS the
workflow.

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

| Tool                    | Config form              | Readable in `git diff` | Standalone | Operator can edit without engineering? |
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

| `interface …`     | Does what                                | Needs                    |
| ----------------- | ---------------------------------------- | ------------------------ |
| `shell <name>`    | Host process via `Open3`                 | _(default)_              |
| `http <name>`     | `Net::HTTP` GET/POST/… JSON APIs         | _(default)_              |
| `llm <name>`      | Anthropic / OpenAI chat completion       | _(default)_              |
| `webhook <name>`  | Inbound HTTPS endpoint with bearer auth  | _(default)_              |
| `manual <name>`   | Inbound entry for `prouter trigger`      | _(default)_              |
| `docker <name>`   | OCI container with image / memory / cpu  | `gem install docker-api` |
| `postgres <name>` | SQL with `$1..$N` bind params            | `gem install pg`         |
| `cron <name>`     | Inbound cron schedule                    | `gem install fugit`      |

Adding your own type is one plugin file + one caller class — no edits
to parser/validator/renderer/CLI. See [CLAUDE.md](CLAUDE.md) for the
worked recipe.

## What you get with it

- **Versioned config history.** Every `apply` is a git-style commit.
  `show config commits`, `rollback`, `diff file running-config`.
- **Smart retries.** `retry attempts 3 backoff exponential` plus
  `retry when error_type in "timeout","http_status"`. Retry attempts
  see `{{previous.error_type}}` and `{{iteration}}` for retry-with-feedback.
- **Replay.** Re-run a finished run with the same input + same config
  commit (even if the running config has moved on), or start
  mid-pipeline from a chosen block.
- **Output contracts.** Declare expected JSON shape, validate at
  runtime, fail / retry / warn on violation.
- **Typed artifacts.** `produces model.pkl`, `input from train.model.pkl`.
  Files between blocks, not just JSON.
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

Production-ready core. 630 specs, 0 failures. End-to-end smoke-tested
against real Docker, Puma, cron, and shell exec. Web console
(`prouterd-web`) ships separately and talks to the daemon over `/v1`
HTTP + `/v1/events` WS.

Out of scope for v0.1 (the plugin interfaces are ready — write a plugin
file and a caller class, no core edits): KubernetesCaller, S3
ArtifactStore, Vault / AWS Secrets Manager, RBAC / mTLS / OIDC,
Postgres-as-storage-backend, idempotency keys.

See [CHANGELOG.md](CHANGELOG.md) for the per-version breakdown
(32 phases shipped).

## License

MIT.
