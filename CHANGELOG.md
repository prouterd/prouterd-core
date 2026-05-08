# Changelog

## v0.1 — 2026-05-02

### Phase 1: .prc config language
- Line-oriented lexer with quoted strings, comments, line/column tracking
- Recursive parser with `exit`-bounded sections for router / secret /
  policy / queue / interface / process / block / route
- AST + validator (refs, cycles, multi-incoming, missing image, entry blocks)
- Canonical renderer (idempotent under parse→render→parse)
- `prouter check` and `prouter render` CLI

### Phase 2: router-style interactive shell
- Mode stack: user `>`, privileged `#`, config `(config)#`,
  config-process, config-block, plus per-section sub-modes
- Candidate-config flow with `commit` / `abort` / `exit`
- `show` subsystem (running-config, processes, interfaces, etc.)
- `prouter shell` + `prouter exec`

### Phase 3: SQLite-backed config lifecycle
- Schema 0001: `config_commits`, `config_pointers` (running, startup)
- ConfigStore facade: commit / rollback / write_memory / load_running
- `prouter apply` non-interactive commit
- `--db PATH` flag everywhere; `PROUTERD_DB` env

### Phase 4: Runtime core
- Schema 0002: `runs`, `run_steps`, `run_logs`, `artifacts`
- `Runner` adapter with `DockerRunner` (real, via docker-api) +
  `StubRunner` (test fixture)
- Orchestrator: DAG walk from entry blocks, Context dotted-paths,
  per-block input/output/artifacts, secret env resolution
- `prouter trigger`, show runs/run/logs/artifacts
- ArtifactStore (filesystem, S3-ready interface)
- Lexer fix: `String.new` defaults to ASCII-8BIT, breaks SQLite TEXT
  parameterized queries — strings now constructed UTF-8

### Phase 5: Routes and conditions
- MatchEvaluator: 8 operators (`eq`/`neq`/`gt`/`gte`/`lt`/`lte`/`exists`/`in`)
- Level-by-level parallel execution via threads + per-run mutexes
- Tracer: static "what would happen" walk with runtime-dependent
  annotations; TracerRenderer renders the canonical text format
- `prouter trace event <file>`
- Renderer fix: `command` always quoted (preserves shell metacharacters
  through render→parse roundtrip)

### Phase 6: Retries, on-failure, dead-letter, replay
- RetryCalculator (fixed/exponential/linear backoff with max-delay cap)
- Per-attempt step rows, "retrying" system log lines between attempts
- on-failure stop / continue (per-route) — failed branches can be pruned
  while others proceed
- `show dead-letter`, `prouter replay run <uid>`
- Replay re-executes against the run's PINNED config commit (not current
  running) so behavior is reproducible

### Phase 7: Webhook HTTP daemon
- Rack 3 + Puma, `prouter serve [--bind --port --db --runner]`
- `POST /i/<interface_name>` with bearer auth (constant-time compare)
- `GET /v1/status` health endpoint
- Async dispatch (Thread.new — Phase 11 replaces with worker pool)

### Phase 8: Replay-from-block, crash recovery, redaction
- `replay run <uid> from <block>` — seeds context from captured
  step.input_json["context"] and starts orchestrator at named block
- Recovery sweep on daemon boot: orphaned `running`/`queued` runs and
  steps marked failed
- Redactor scrubs every declared secret value from logs / error_summary
  / step.error_message before persistence

### Phase 9: cancel, diff, cron
- `cancel run <uid>` — soft cancel via run.status=canceled, orchestrator
  polls between levels
- `diff <file> running-config` — shows what would change
- Cron scheduler (fugit) inside `prouter serve` — fires `interface cron`
  declarations at their schedule

### Phase 10: Production hardening
- Full `/v1/*` HTTP API (config, processes, runs, logs, artifacts,
  trace, replay, cancel) with admin bearer auth from `PROUTERD_ADMIN_TOKEN`
- `/metrics` Prometheus text format (counters + uptime + in_flight gauge)
- InFlightRegistry tracks `run_uid → container_id`; `POST /v1/runs/:uid/cancel`
  hard-kills attached Docker containers
- Graceful shutdown: app.stop_accepting → drain registry → puma.stop(true)
- Webhook `method` field actually enforced (405 + Allow header on mismatch)
- `prouter cleanup --older-than 30d [--dry-run]` retention sweep
- LICENSE (MIT)
- DB encoding fix at `Storage::DB#execute` — Rack path segments arrive
  ASCII-8BIT, normalized to UTF-8 at the bind layer (defense-in-depth)

### Phase 11: Persistent job queue + crash-survivable in-flight runs
- Schema 0003: `jobs` table with status / locked_by / locked_at /
  available_at / attempts / payload_json
- Repositories::Jobs with atomic `claim` (UPDATE … RETURNING) — race-free
  under SQLite WAL even with N workers
- Runtime::WorkerPool: configurable thread count (`--workers N`,
  default 4) drains the queue
- Webhook handler / `/v1/processes/:name/trigger` / `/v1/runs/:uid/replay` /
  cron scheduler all enqueue jobs instead of spawning Thread.new
- Recovery extended: locked jobs older than 60s are re-queued at daemon
  boot — daemon crash mid-run no longer drops work
- `Reline` in interactive shell (history + line editing) when available
- `RateLimiter` per webhook interface (sliding window, default 60/sec,
  override via `PROUTERD_WEBHOOK_RATE=MAX/WINDOW`)
- CHANGELOG (this file)

### Phase 12: Block execution types (Docker + Shell), pluggable runners
- DSL: each block declares `type docker { image / pull / network / user /
  memory / cpu }` or `type shell { exec / cwd / shell / env }` as a
  sub-section. Common fields (input/output/timeout/retry/secret/contract/
  enable|disable) stay on the block.
- New `Runner::ShellRunner` — Open3-based local exec, same
  `/prouter/{input,output,artifacts}` contract as DockerRunner, same
  `ExecutionResult` shape. Logs/artifacts/redactor/retries are
  runner-agnostic.
- Orchestrator `runner:` argument now accepts `Hash<String, Runner>`
  and dispatches per-block by `block.execution_type`. Single-runner
  legacy form still works.
- CLI: `--runner docker` builds both runners (DockerRunner +
  ShellRunner) so mixed pipelines work out of the box. `--runner shell`
  routes both keys to ShellRunner for docker-less hosts.
- Block gains `contract <name>` field (parsed + persisted; runtime
  JSON-Schema enforcement deferred to a later phase), plus `enable`/
  `disable` shorthand and `retry <name>` short form alongside legacy
  `shutdown`/`no shutdown` and `retry policy <name>`.
- Backwards compat: pre-Phase-12 inline form (`image foo` directly
  inside block) parses with `execution_type=docker` auto-inferred.
  Renderer emits canonical Phase 12 form, so an apply→reload migrates
  configs automatically.
- `show block process P B` and Tracer policies output now show
  type-specific fields (image/command/network/pull/user/memory/cpu vs
  exec/cwd/shell/env). `show process P` block listing tags each block
  with its type.
- New `examples/06_shell_block.prc` demonstrates a shell→docker
  pipeline. End-to-end smoke verified: `prepare` (shell, 1ms) →
  `finalize` (docker, 171ms), both under one run.

### Phase 13: IPC foundation — Events bus + WS endpoints
- `Prouterd::Events` in-process pub/sub bus with topic subscriptions.
- WS endpoints: `/v1/events` (subscribe to run/step/log/commit events)
  and `/v1/cli/:session_id` (remote CLI session over websocket).
- Orchestrator publishes `run_created`, `run_updated`, `step_created`,
  `step_updated`, `log_appended` to the bus.
- Companion gem `prouterd-web` consumes these for live UI updates.

### Phase 14: Contracts — router-style output validation in DSL
- Top-level `contract <name>` section with `require/optional <path>`
  and constraint attributes: `type`, `min/max`, `length/min-length/
  max-length`, `format` (email/uri/uuid/iso8601), `pattern`, `in`.
- Multi-line accumulation: each line is one constraint, lines for the
  same path collapse into one Requirement.
- `on violation fail|retry|warn` policies wired into the orchestrator
  after runner success: a violation reshapes the result, fail or retry
  reuses the block's existing retry policy, warn keeps success.
- Universal across runners — same hook fires for `type docker` and
  `type shell` (and any future runner type).
- 30 specs across parser, validator, renderer, ContractValidator,
  orchestrator integration. Smoke verified: real container outputs
  bad JSON, run fails with detailed violation list.

### Phase 15: Distribution — Dockerfile + docker-compose
- Two-stage `Dockerfile` (ruby:3.2-slim builder + slim runtime).
  Final image is 169MB. Non-root user, persistent `/data` volume,
  bundle path baked in.
- `docker-compose.yml` with healthcheck, volume, optional Docker socket
  mount for `type docker` blocks.
- `.dockerignore` strips dev fixtures + tests + docs from the build
  context.
- README "Quick start" gains a Docker option above the Ruby option, so
  a new user can `docker build && docker run` without touching the host's
  Ruby environment.
- Smoke verified: image builds, daemon answers `/v1/status` within
  ~2.5s of container start, admin auth chain (401/403/200) passes,
  one-shot CLI invocations work via `docker run ... <command>`,
  persistent volume preserves DB across container lifecycles.

### Phase 16: Plugin-driven runner types
- New `Runner::Plugin` base class + `Runner::Registry`. A new runner
  type is one plugin file (declares `type "name"`, lists fields with
  `field :foo, kind: :string|:enum|:command|:env_pair`, points at a
  Runner class) plus the runner itself — no edits to parser, validator,
  renderer, show, tracer, or CLI.
- Built-in `docker` and `shell` types extracted into
  `lib/prouterd/runner/plugins/{docker,shell}.rb`. Same DSL surface,
  100% backward compatible (legacy inline `image foo` form still
  parses and auto-infers `type docker`).
- `AST::Block` switched from named slots (image/command/network/...)
  to a generic `type_fields` Hash. Parser/validator/renderer/show/
  tracer all iterate over the active plugin's declared fields rather
  than hardcoding type names.
- `RunRequest` consolidated: type-specific fields collapsed into
  `type_fields:` hash. Runners read what they need via
  `request.field("image")` etc. Adding a runner type doesn't change
  the struct.
- CLI `build_runner` builds the runners hash from the registry —
  `prouter serve --runner real` (default) instantiates one runner per
  registered plugin. `--runner stub` swaps every type to StubRunner
  for tests.
- `spec/prouterd/runner/plugin_spec.rb` is the worked reference: defines
  a fake `printer` plugin in-test and asserts parse → validate →
  render → orchestrate end-to-end on it. 9 specs.
- CLAUDE.md gains a self-contained "Adding a new runner type" section
  with copy-paste plugin + runner skeleton.

### Phase 17: Production hardening pass

Closes the rough edges from the Phase-16 audit. Every new behavior
is gated by an env var with a sensible default, and every component
that already accepted a `logger:` kwarg now actually receives a real
one when launched through `prouter serve`.

Operational:
- `Prouterd::Logger` — single-line, kv-pair format with timestamp/level.
  Built once in `cmd_serve` and threaded through Server, Recovery,
  WorkerPool, Scheduler, App, V1, WebhookHandler, Orchestrator. No more
  `@logger&.error(...)` no-ops in production. Level via
  `PROUTERD_LOG_LEVEL` (debug/info/warn/error/fatal).
- HTTPS: `prouter serve` reads `PROUTERD_SSL_CERT` / `PROUTERD_SSL_KEY`
  and binds via Puma's MiniSSL when both are set, otherwise plain HTTP
  on the same `--bind --port`.

Resource caps (the daemon will not OOM on a misbehaving block or
attacker):
- Body size limit: `PROUTERD_MAX_BODY_BYTES` (default 1 MB) applies to
  webhooks and most `/v1` POSTs; `PROUTERD_MAX_CONFIG_BYTES`
  (default 4 MB) applies specifically to `/v1/config/apply` and
  `/v1/config/check` since DSL files can grow. Returns 413 with the
  cap reported in the body.
- Container log capture cap: `PROUTERD_LOG_CAPTURE_BYTES` (default 1 MB
  per stream) — `DockerRunner` truncates persisted stdout/stderr after
  the cap with a `…[truncated to N bytes]` marker. Block can still
  write more — `docker logs <cid>` shows the rest.
- Artifact download streaming: `/v1/artifacts/:id/download` now uses
  a chunked Rack body (64 KB reads) so multi-GB artifacts no longer
  materialize in daemon memory.

Robustness:
- Graceful container stop: `DockerRunner#force_stop` and
  `POST /v1/runs/:uid/cancel` now SIGTERM via `container.stop(t: 10)`
  (configurable via `PROUTERD_CONTAINER_STOP_TIMEOUT`) and only escalate
  to SIGKILL on failure. Blocks get a chance to flush logs / write
  output.json before being torn down.
- `RateLimiter` periodically evicts empty buckets (default every 60s)
  so the bucket map can't grow unbounded across many distinct webhook
  interface names over a long-running daemon.
- Recovery sweep's job-lock timeout is now configurable via
  `PROUTERD_JOB_LOCK_TIMEOUT` (default 60s) — relevant for blocks whose
  per-attempt `timeout` exceeds 60s.

Configurability / portability:
- File-based secrets: `secret X / source file /run/secrets/x` reads
  the file (trailing newline trimmed). Works with Docker Compose
  secrets, Kubernetes secret volumes, systemd LoadCredential.
- `PROUTERD_ARTIFACTS_ROOT` overrides where `ArtifactStore` writes —
  for systemd boxes (`/var/lib/prouterd/artifacts`), container images
  (`/data/artifacts`), or shared mounts.
- `prouter cleanup --batch-size N` (default 500) splits the delete
  pass into small transactions so a million-run sweep doesn't lock
  the DB for minutes.

23 new specs (Logger, body limit, secret resolver, rate-limiter
eviction, log capture cap), bringing the suite to 494 specs / 0
failures.

### Phase 18: router-CLI compatibility pass

Closes the «router-CLI conformance» audit. The shell now matches
real OS muscle memory in the places where it diverged: prefix
abbreviation, `end`, `do`, `?`-as-context-help, `copy run start`,
`logout`/`quit`, the iconic `show clock`/`logging`/`history` targets,
the `show run` collision, and unquoted `description` text.

Dispatch refactor — single source of truth:
- `Mode#execute` does prefix expansion (`sh run` → `show running-config`,
  `conf t` → `configure terminal`, `wr m` → `write memory`, `dis` →
  `disable`). Exact match always wins; an ambiguous prefix raises with
  the candidate list (`% ambiguous command 'c': cancel, configure, copy`).
- All five config sub-modes (Section, ConfigProcess, ConfigBlock,
  ConfigGlobalRoute, ConfigProcessRoute) now declare commands via the
  base `commands` Hash and override `apply_field` for the
  parser-delegating fall-through. Per-mode custom `execute` overrides
  are gone — one dispatch path everywhere.
- Multi-word command keywords (`configure terminal`, `write memory`,
  `copy running-config startup-config`, `rollback commit <id>`,
  `trigger process <name> input <file>`, `replay run <uid> from <block>`,
  `cancel run <uid>`, `trace event <file> [interface <name>]`,
  `diff <file> running-config`) all accept abbreviated keywords via
  `match_keyword?`.

New commands:
- `end` — from any config sub-mode, jumps straight back to privileged.
  Candidate is preserved (use `commit` to promote it, `abort` to drop).
- `do <command>` — runs a privileged-mode command from inside any
  config sub-mode without exiting first. Mode-changing commands
  (`configure`, `disable`, `exit`/`end`/etc.) are blocked so `do`
  can't accidentally push or pop modes.
- `logout` / `quit` — aliases for `exit` in user and privileged modes.
- `copy running-config startup-config` — modern router-OS spelling for
  `write memory` (legacy form still works).

Context-sensitive `?`:
- Bare `?` runs the mode's help (unchanged).
- A trailing `?` (`show ?`, `show run ?`, `replay ?`) is intercepted by
  `Mode#execute` before dispatch and routed to `Completer` for the
  enumeration of valid next tokens. router CLIs print `<cr>` when no further
  input is expected — we mirror that.

Show subsystem:
- New targets: `show clock` (UTC timestamp + day/month), `show logging`
  (level + format + capture cap from the actual env), `show history`
  (Reline session command history; politely declines without Reline).
- Bare `show run` (no UID) now means `show running-config` — the router
  habit. `show run <uid>` keeps its prouter-native run-detail meaning.
- Show targets get the same prefix expansion (`sh run-c`, `sh int`,
  `sh pol`). Singular/plural pairs are disambiguated by argument
  presence: bare `sh int` → `interfaces` (listing), `sh int demo` →
  `interface` (detail). `show clock` is whitelisted in user mode.

Free text:
- `description` consumes the rest of the line as router-style free text
  — quotes are no longer required for spaces. Renderer re-quotes on
  output so roundtrip stays idempotent and pre-existing quoted forms
  still parse identically.

31 new specs in `spec/prouterd/shell/router_cli_compat_spec.rb` covering
prefix expansion, ambiguity, `end`/`do`, `?` context help, `logout`/
`quit`/`copy`/`show clock|logging|history`, `show run` collision, and
multi-word `description` parser/render roundtrip. Suite now at 525
examples / 0 failures.

### Phase 19: Two-binary split (prouter CLI + prouterd daemon)

The `serve` subcommand of `prouter` is gone. The long-running daemon
now lives in its own binary, `exe/prouterd`, mirroring the etcd /
dockerd / containerd convention where the daemon owns the brand name
and the operator client is a separate, sharper binary.

Binary surface:
- `exe/prouter` — operator CLI client. Subcommands: check, render,
  apply, shell, exec, trigger, replay, cancel, diff, cleanup, trace,
  version, help. No daemon mode.
- `exe/prouterd` — long-running daemon. Flags: `--bind`, `--port`,
  `--db`, `--workers`, `--runner`, `--no-db`, `--version`, `--help`.
  Replaces what used to be `prouter serve <those-flags>`.

Implementation:
- Extracted `cmd_serve`'s logic to a new `Prouterd::Daemon::Main` class
  in [lib/prouterd/daemon.rb](lib/prouterd/daemon.rb). Same dependency
  graph (Logger, Recovery, WorkerPool, Scheduler, RateLimiter, App,
  Server) — daemon code is now structurally separate from the CLI.
- New `Prouterd::Bootstrap` mixin in [lib/prouterd/bootstrap.rb](lib/prouterd/bootstrap.rb)
  shares `default_runner_kind`, `open_store`, `build_runner` between
  CLI and daemon — single source of truth for `--db` / `--runner`
  resolution.
- `Prouterd::CLI::Main` includes Bootstrap and lost its private copies.
- `prouter help` text drops the `serve` line and points at `prouterd
  --help` instead.
- `prouterd.gemspec` ships both `prouter` and `prouterd` as
  `spec.executables`.
- Dockerfile entrypoint changed from `exe/prouter serve` to
  `exe/prouterd`. CMD trimmed accordingly.
- `examples/README.md` webhook + cron demos use `exe/prouterd` to
  launch the daemon (was `exe/prouter serve`).

7 new specs in `spec/prouterd/daemon/main_spec.rb` cover argv parsing
(`--port` / `--workers` integer validation, unknown flag rejection,
`--bind` missing-value rejection, `--version` / `--help`
short-circuits) and the `--no-db` rejection that the daemon needs
persistent state. Suite at 532 examples / 0 failures.

Migration: any external script doing `prouter serve --bind X --port Y`
must change to `prouterd --bind X --port Y` (same flags, different
binary). Inside Docker the entrypoint switch is invisible to operators
who use the default `docker run prouterd:latest`.

### Phase 20: Typed artifacts — files between blocks

Closes the long-standing gap where `output.json` was the only sanctioned
way to pass data between blocks. ML / data pipelines need to hand
parquet, pickle, model binaries downstream — sticking those into JSON
was the obvious anti-pattern. The runtime already archived
`/prouter/artifacts/` to disk, so this phase just adds the DSL surface
to declare-and-consume that archive across blocks.

DSL additions:
- `produces <relpath>` (block-level) — declares a file the block MUST
  write into `/prouter/artifacts/`. Multiple per block. Missing on
  success → `error_type: "missing_artifact"`, retry/on-failure applies.
- `input from <upstream_block>.<relpath>` (block-level) — pulls the
  named artifact from the upstream's archive. The local name (used for
  the staged path and env var) is derived from the basename minus its
  last extension: `model.pkl` → `model`, `metrics.json` → `metrics`.
- Existing `input <ctx.path>` (event-data flow) remains; the two are
  orthogonal abstractions and can coexist on the same block.

Runtime:
- Orchestrator `stage_artifact_inputs` looks up archived rows in the
  `artifacts` table by `(block_name, name)` and hands a
  `Hash<local_name, host_path>` to the runner via the new
  `RunRequest.staged_inputs` field.
- `DockerRunner#stage_inputs` and `ShellRunner#stage_inputs` copy each
  staged file into `<work_dir>/inputs/<local_name>` — exposed at
  `/prouter/inputs/<local_name>` inside Docker, at the host path for
  shell.
- Env: `PROUTER_INPUT_<UPPER(local_name)>` → the staged path, alongside
  the existing `PROUTER_INPUT_PATH` (the event JSON).
- `enforce_produces` reshapes a successful result into a
  `missing_artifact` failure if any declared `produces` file is absent;
  uses the same retry / on-failure machinery as any other block error.

Validator:
- Cross-process refs: `input from Y.Z` requires Y to be a block in the
  same process AND declare `produces Z`.
- Topology check: Y must be reachable upstream of the consumer in the
  route graph.
- Collision check: two inputs deriving the same local name
  (e.g. `train.model.pkl` + `train.model.json`) error with a fix-it
  pointer to rename `produces` upstream.

No DB migrations needed — the existing `artifacts` table already keys
on `(run_id, block_name, name)`. No `/v1` API changes — artifacts were
already exposed.

Spec coverage: 18 new specs (parser: 4, renderer roundtrip: 1,
validator: 5, e2e via StubRunner: 2, plus existing-form regressions).
Suite at 550 examples / 0 failures.

Worked example in [examples/08_typed_artifacts.prc](examples/08_typed_artifacts.prc).

### Phase 23: Unify the block model around outbound interfaces

Phases 12 and 16 split execution into two parallel concepts:
**inbound interfaces** (webhook / cron / manual) declared at the top
level, and **runner types** (`type docker { ... }` / `type shell { ... }`)
nested inside each block. They lived in two different plugin
registries (`Iface` for inbound, `Runner` for outbound), with two sets
of plugin classes, two field-schema mechanisms, and two dispatch
paths. Block bodies grew tangled: a `type docker` sub-section, plus
an `input <ctx.path>` directive, plus an `output <ctx.path>` directive,
plus call-args in the type sub-section. Adding `interface http jira`
would have meant a third pattern.

This phase collapses everything into one concept: **interfaces have
direction**.

- One registry: `Iface::Registry` with `direction :inbound` (webhook,
  cron, manual) or `:outbound` (docker, shell, http).
- One plugin base class: `Iface::Plugin`, declaring `field` (interface
  body) and `call_field` (per-block-call args, templated at runtime).
- Outbound plugins point to a caller class via `caller "ClassName"`;
  CallRunner replaces the old DockerRunner / ShellRunner dispatch.
- Blocks reference interfaces by full form: `interface <type> <name>`,
  symmetric with the declaration. The type stays visible at the call
  site, so both `interface docker enricher` and `interface http jira`
  are obvious from one line.
- `block.input` / `block.output` directives are gone. Inputs flow
  through `{{path}}` templating (`Util::Templater`, lightweight,
  intentionally not a full expression language) inside call-field
  values. Outputs are auto-keyed at `context[block.name]`.
- `Runner::Plugin` registry, the `runner/plugins/` directory, the old
  per-block `type X { ... } exit` parsing, and the `block.execution_type` /
  `block.image` / `block.command` accessors all dropped — no
  legacy compatibility paths.

Migration touched everything: AST, parser, validator, renderer,
orchestrator, tracer, show formatter, completer, all 9 examples, both
fixtures, ~330 spec lines. `interface http <name>` lands as a built-in
caller backed by `Net::HTTP` (no external HTTP gem), so the canonical
"hit Jira from a block" example is one block, not a custom runner.

Suite at 561 examples, 0 failures.

### Phase 24: `interface llm` — provider-dispatching outbound

A first-class outbound `interface llm <name>` lands as a built-in
plugin alongside docker / shell / http. One DSL keyword, two providers
(`anthropic`, `openai`), one Net::HTTP-based caller — no extra gem
dependency.

```
secret CLAUDE_KEY
 source env CLAUDE_KEY
exit

interface llm claude
 provider anthropic
 model claude-haiku-4-5-20251001
 auth bearer secret CLAUDE_KEY
exit

process triage
 block summarize
  interface llm claude
  system "You summarize tickets in one sentence."
  prompt "{{event.body}}"
  max-tokens 256
 exit
exit
```

The plugin-level `auth bearer secret <NAME>` resolves to the API key,
which the caller then attaches as the provider's expected header
(`x-api-key` for Anthropic, `Authorization: Bearer …` for OpenAI). The
output JSON is provider-shaped on the way out: `{text, model, usage,
stop_reason, raw}` — downstream blocks reference `{{summarize.text}}`.

Per-call fields (`prompt`, `system`, `max-tokens`, `temperature`) are
all `:string` so `{{...}}` templating works on every one of them; the
caller parses int/float at dispatch time.

15 new specs: 8 caller, 7 plugin schema. Suite at 577 examples, 0
failures.

Worked example in [examples/09_llm.prc](examples/09_llm.prc).

### Phase 25: Smart retries — `retry when`, `{{previous}}`, `{{iteration}}`

The retry policy gains a condition: `retry when <path> <op> <value>`,
reusing the same operators as route matches (`eq`, `neq`, `in`, `gt`,
`gte`, `lt`, `lte`, `exists`). Multiple `retry when` clauses OR
together — any one matching is enough to retry. Zero clauses preserve
the original behaviour ("retry on any failure").

```
policy transient_only
 retry attempts 3
 retry backoff exponential
 retry initial-delay 500ms
 retry when error_type in "timeout","http_status","http_error","llm_error"
exit
```

The condition is evaluated against a synthetic context built from the
failure result: `error_type`, `error_message`, `exit_code`. If no
clause matches, the orchestrator logs a one-line system message and
treats the failure as terminal — no more attempts even if `attempts`
isn't exhausted.

Two new templating variables become available inside call-fields:

- `{{iteration}}` — 1-indexed attempt number, set on every attempt
- `{{previous}}` — on attempts 2+, a hash of the prior attempt's
  `attempt`, `error_type`, `error_message`, `exit_code`, `stdout`,
  `stderr`. Useful for "retry with feedback" patterns where the
  prompt embeds the prior error.

Both flow through a per-attempt overlay context (`OverlayContext`)
that wraps `Runtime::Context` for templating only. Parallel block
attempts at the same DAG level cannot see each other's iteration /
previous values — the overlay is per-call, not run-shared.

7 new specs cover: retry-when matches and skips, `in` with multiple
error types, iteration starting at 1, previous shape on retry,
overlay isolation between blocks, parser/renderer roundtrip.

Worked example: [examples/11_retry_when.prc](examples/11_retry_when.prc).
Suite at 584 examples, 0 failures.

### Phase 26: `interface postgres` + Jira-debug worked example

A first-class outbound `interface postgres <name>` plugin lands
alongside docker / shell / http / llm. Per-call `query "..."` plus
optional `params "..."` (comma-separated, bound to `$1..$N`).
Statement timeout configurable on the interface, applied as
`SET LOCAL statement_timeout = …` inside a per-call transaction.

```
secret PG_DSN
 source env PG_DSN
exit

interface postgres warehouse
 dsn "{{secret.PG_DSN}}"
 statement-timeout 5000
exit

block lookup
 interface postgres warehouse
 query "SELECT id, status FROM tickets WHERE key = $1"
 params "{{event.issue.key}}"
exit
```

The `pg` gem is required lazily by the caller — installations that
never use `interface postgres` don't pay the dependency cost. If pg
is missing at first call, the caller returns a clean
`error_type: "missing_dependency"` result that retry-when can then
choose to skip. SQLSTATE `57014` (statement-timeout-cancel) is
mapped to `error_type: "timeout"` so retry policies that include
`timeout` in their `retry when ... in` list catch slow queries
naturally.

13 new specs cover: missing-pg fallback, exec / exec_params dispatch,
result shape, comma-split params, statement-timeout SET LOCAL,
error categorisation (sql_error vs timeout via SQLSTATE),
parser/validator/renderer plugin schema.

The companion **examples/12_jira_debug/** demonstrates the full
unified-interface story end-to-end: a webhook fires the pipeline,
`interface http jira` pulls the ticket, `interface postgres
warehouse` looks up history, `interface llm claude` writes a debug
brief, and `interface http jira` posts it back as a comment. One
`policy transient_only` covers retries across all four outbound
calls. This is the canonical "ticket comes in, Claude debugs it"
workflow the unification phases were aimed at.

Suite at 597 examples, 0 failures.

### Phase 27: Fix outbound dispatch + iface-body templating

Three bugs from Phases 23–26 made the new outbound interfaces look
right on paper but fail end-to-end:

1. **Dispatch contract mismatch.** `CallRunner#run` calls
   `instance.run(request)` but the new HttpCaller / LlmCaller /
   PostgresCaller exposed `call(iface:, call_fields:, secrets:,
   timeout_ms:)`. Unit tests passed because they invoked `.call`
   directly; nothing exercised the orchestrator path. **Fix:** all
   three callers now expose `run(request) -> ExecutionResult`,
   reading from `request.type_fields` (orchestrator-merged iface
   body + templated call fields) and `request.env` (resolved auth
   tokens). The Caller-internal `CallerResult` struct is gone — they
   return the same `Runner::ExecutionResult` everything else uses.

2. **Interface-body fields weren't templated.** `dsn "{{secret.PG_DSN}}"`
   on `interface postgres` was stored verbatim and handed to
   `PG.connect` as a literal string. The orchestrator only templated
   `block.type_fields`. **Fix:** orchestrator now templates
   `iface.type_fields` too, with the same overlay scope as call
   fields. Both happen per-attempt (so `{{iteration}}` is consistent
   across iface+call) and are merged with call-field winning on
   conflict.

3. **No `secret.*` resolver in templating.** Operators can now write
   `dsn "{{secret.PG_DSN}}"` and the orchestrator looks the secret up
   via the configured `secret_resolver`, exposes a `secret` namespace
   on the per-attempt overlay, and substitutes the resolved value at
   call time. The map is memoized per run.

Plus two follow-on fixes:

4. **Templater & Context array indexing.** `{{event.tags.0}}` now
   indexes into Array values instead of silently returning empty
   string. Both `Util::Templater.resolve` and `Runtime::Context#get`
   accept numeric path components.

5. **Iface auth secret in env.** `interface http jira { auth bearer
   secret JIRA_TOKEN }` previously required the BLOCK to also declare
   `secret JIRA_TOKEN` for the resolved value to reach env. Now
   `build_env` resolves the iface's auth secret automatically so
   HttpCaller / LlmCaller find the bearer token without any
   redundant block-side declaration.

Cleanups:
- `secret_resolver:` kwarg dropped from caller initializers — was
  always nil and never read.
- `PostgresCaller#parse_params` rewritten to honour quoted values, so
  `params '"Doe, John",42'` no longer splits inside the quoted comma.
- New integration spec (`outbound_dispatch_spec.rb`) drives orchestrator
  → CallRunner → caller end-to-end for http and postgres, exercising
  templating + secret resolution + array indexing.

The end-to-end Jira-debug example
([examples/12_jira_debug/](examples/12_jira_debug/)) now actually
works as documented.

Suite at 605 examples, 0 failures.

### Phase 28: Heavy interface deps become opt-in

Phase 26 made `pg` lazy because not every install needs postgres. The
same reasoning applies to `docker-api` (a heavy native gem; many
operators don't run a Docker daemon at all) and `fugit` (only
`interface cron` uses it). Phase 28 generalises the pattern so the
**default install gives you `interface shell` + `interface http` +
`interface llm`** — all three sit on Ruby stdlib (`Open3`, `Net::HTTP`).
Container, SQL, and cron support are explicit `gem install` away.

```
gem install docker-api   # interface docker     (DockerRunner)
gem install pg           # interface postgres   (PostgresCaller)
gem install fugit        # interface cron       (Scheduler)
```

What changed:

- **DockerRunner** lazy-loads `docker-api` on first dispatch via
  `DockerRunner.docker_available?`. Without the gem it returns
  `error_type:"missing_dependency"` with the install command, instead
  of `LoadError`-ing at require time.
- **api/v1.rb** cancel-attached path is guarded with the same check
  so a daemon started without docker-api can't `NameError` on
  `Docker::Container.get`.
- **Scheduler** lazy-loads `fugit` via `Scheduler.fugit_available?`.
  Without the gem it logs once ("'fugit' gem not installed; cron
  interfaces disabled") and returns nil from `parse_cron` — the daemon
  keeps running, webhook + manual interfaces are unaffected.
- **gemspec** now lists only `sqlite3`, `puma`, `rack`,
  `faye-websocket` as hard runtime deps. `docker-api`, `pg`, and
  `fugit` move to `add_development_dependency` so CI keeps testing
  against them. The `add_dependency` line for each is replaced with a
  table of optional features in the gemspec comment block.
- **examples/01_hello_world.prc** rewritten to use `interface shell`
  so the default install actually runs the canonical hello-world
  without docker.

Three new specs prove the missing-dep paths:
`spec/prouterd/runner/docker_runner_missing_dep_spec.rb` (unit + e2e
through CallRunner) and
`spec/prouterd/runtime/scheduler_missing_fugit_spec.rb` (warns once,
disables firing). PostgresCaller's existing missing-pg coverage from
Phase 26 already proves the pg path.

Suite at 608 examples, 0 failures.

### Phase 29: ShellRunner relaxes the output.json contract; hello-world readable again

A shell block with `exec "true"` previously failed with
`error_type:"missing_output"` — every shell block had to synthesize
JSON into `/prouter/output.json` to be considered successful. Combined
with DSL-level quote escaping, this produced things like:

```
exec "sh -c 'NAME=$(cat $PROUTER_INPUT_PATH | sed -n \"s/.*\\\"name\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p\"); echo \"hello, $NAME!\" >&2; echo \"{\\\"greeted\\\":\\\"$NAME\\\"}\" > $PROUTER_OUTPUT_PATH'"
```

…in the canonical hello-world. That's parsing JSON via sed inside four
levels of quote escaping inside a templating engine that fixed exactly
this problem two phases ago.

**Fix:**
- ShellRunner: exit 0 + missing/empty `output.json` = success with
  `output_json = {}`. Side-effect-only blocks (echo, notify, tail) no
  longer need ceremony to be valid. DockerRunner stays strict — the
  container contract is its whole point.
- `output.json` malformed JSON still surfaces as `invalid_output`.
- examples/01_hello_world.prc rewritten:
  ```
  block greet
   interface shell host
   exec "echo hello, {{event.name}}!"
  exit
  ```
  One line. Reads input via `{{event.name}}` templating. No output
  synthesis. No docker. Verified end-to-end:
  `[greet/stdout] hello, world!`.

Existing `shell_runner_spec` test that asserted the strict missing-
output behaviour was rewritten to assert the new lenient one.

Suite at 608 examples, 0 failures.

### Phase 30: Backtick raw strings + stdout-as-JSON kill the \\\\\\" pyramid

The Phase 29 hello-world fix exposed a deeper problem: every example
that needed to emit a JSON literal through shell ended up looking like

```
command "sh -c 'echo \"{\\\"score\\\":85}\" > /prouter/output.json'"
```

— DSL escaping `"` as `\"`, then shell escaping `"` as `\"`, then JSON
needing literal `"`, multiplied through the layers. Operators couldn't
read it, let alone write it.

Two orthogonal changes:

**Backtick raw strings in the DSL.** The lexer now accepts `` `...` `` as
a raw string token: NO escape processing, every byte between the
backticks taken literally. Embedded `` ` `` is not allowed (use the
double-quoted form for that one case). This matches Python's `r"..."`,
Markdown's fenced code, and the half-dozen other DSLs that figured out
quoting nesting is unsolvable in one universe of escapes.

**ShellRunner parses stdout as JSON when output.json is absent.** If a
shell block exits 0 and the optional `/prouter/output.json` file
doesn't exist, the runner trims stdout and tries `JSON.parse`; if it
yields a Hash or Array, that becomes `output_json`. Pure log output
falls through to `{}` (the existing Phase 29 default). The block can
still write the file explicitly to override (file always wins over
stdout). DockerRunner stays strict — the container contract is its
whole point.

Combined, the canonical scorer block goes from

```
command "sh -c 'echo \"{\\\"score\\\":85}\" > /prouter/output.json'"
```

to

```
exec `echo '{"score":85}'`
```

…and the rest of the pipeline reads it via `{{scorer.score}}`. End of
story.

The renderer was taught to emit backtick form when it would noticeably
reduce escaping (string contains `"` or `\`, doesn't contain `` ` ``),
so parse → render → parse stays idempotent on the new form too.

Updated examples 02–09 + 12 + the LLM-notify pipeline; **zero `\\\\\\"`
left in the example tree**. examples/09_llm.prc dropped its sed-pipeline
JSON parser entirely — `{{summarize.text}}` does the same job, declaratively.

9 new specs: 4 lexer (backtick raw, escape literality, unterminated,
word-scan stop), 5 ShellRunner (stdout-Hash, stdout-Array, log-text
fallback, scalar-JSON fallback, file-overrides-stdout). Suite at 617
examples, 0 failures.

### Phase 31: DockerRunner stdout-as-JSON; finish off the escape-pyramid fix

Phase 30 left a known regression I didn't catch in CI: backtick raw
strings stripped DSL-level escaping from docker echo-JSON blocks, but
the shell INSIDE `'...'` then ate the JSON quotes and produced
`{score:85}` (invalid JSON) instead of `{"score":85}`. Examples
04/05/06/07/08 had `command \`sh -c '... echo {"score":85} > out.json'\``
and would have crashed at runtime with `error_type:"invalid_output"`
the first time anyone ran them through real Docker. The rspec suite
didn't exercise the docker dispatch path under real shell, so it
shipped green.

Two fixes in one phase:

1. **DockerRunner gains stdout-as-JSON**, mirroring ShellRunner from
   Phase 29/30. Priority order:
     1. `/prouter/output.json` exists and parses → use it
     2. file is empty → `output_json = {}`
     3. file is missing AND stdout parses as a Hash/Array → use stdout
     4. otherwise (log text, JSON scalar, empty stdout) → `{}`
   Malformed JSON in an *explicit* file still surfaces as
   `invalid_output` — a deliberate write is a deliberate write. The
   `missing_output` error type is gone (matches shell's lenient
   contract). Container-side `> /prouter/output.json` redirect is now
   optional, not required.

2. **Examples 04–08 rewritten** for the stdout-as-JSON path:
     - drop `> /prouter/output.json` from every block that just echoes
       a JSON literal — the runner picks up stdout
     - move the JSON literal into shell single-quotes:
       `echo '{"score":85}'`
     - flip the outer shell quoting from `'...'` to `"..."` so the
       inner single-quote is legal:
       `sh -c "echo extracted >&2; echo '{\"raw\":true}'"`

   Single-statement blocks lose `sh -c` entirely:
   ```
   block scorer
    interface docker alpine
    command `echo '{"score":85,"label":"A"}'`
   exit
   ```

   Examples 10_tg_github also moved to backtick form (was the last
   place with `\"` sprinkled at DSL level).

Result: across 12 example files, **zero `\\\\` and zero DSL-level `\"`**.
The remaining 6 lines of single `\"` in 04/05/06/07/08 are
shell-internal — they're the inner `\"` inside an outer `"..."` so
single-quoted JSON literals can survive the outer wrap. That's a
shell-syntax cost, not a DSL cost; double-shell-quote nesting can't
go below one escape level no matter what the DSL does.

10 new specs in `docker_runner_classify_outcome_spec.rb` cover every
branch of the new precedence (file present + parses, file present +
empty, file present + invalid, file missing + stdout Hash, file
missing + stdout Array, file missing + log text, file missing + JSON
scalar, file missing + empty stdout, file overrides stdout, non-zero
exit beats everything).

Suite at 627 examples, 0 failures.

### Phase 32: /v1 API surfaces new model — secret_names, retry_when, plugin-driven interfaces

The unification + retry-when phases (23-25) added DSL-level fields
that never made it into the JSON envelope `prouterd-web` consumes.
Web rendered "image / input / output" columns as `—` for every
block because those keys had been replaced with `interface` /
`call_fields`, and there was no way to display Phase 22's
plugin-driven interface fields (http base-url, llm provider, postgres
dsn, …) — `interface_summary` hardcoded webhook + cron paths only.

Three additions to `/v1`:

1. **`process_detail.blocks[i]`** now carries `secret_names: [...]`.
   Web can show which secrets a block injects without scraping the
   rendered config.

2. **`policy_summary`** carries `retry_when: [{path, operator,
   values}, ...]` — Phase 25's smart-retry conditions become
   visible to operators.

3. **`interface_summary`** is now plugin-driven. Iterates
   `Iface::Registry.lookup(i.type).fields`, dumps every populated
   field under a `fields: {...}` sub-hash, and exposes
   `direction: "inbound"|"outbound"`. http / llm / postgres /
   docker / shell all render correctly without core knowing each
   type. `auth bearer secret X` flattens to `"bearer X"` (resolved
   token never leaves the daemon).

3 new specs cover the new shapes. Existing v1 spec still passes —
the additions are pure-add to the response envelope.

630 specs / 0 failures.

### Phase 33: Extract HttpClient + CallerTiming, drop boilerplate from outbound callers

HttpCaller, LlmCaller, and PostgresCaller all duplicated the same
two boilerplate cores:

1. **Net::HTTP transport** (HttpCaller + LlmCaller) — `Net::HTTP.start`
   with the same SSL/timeout knobs, the same `Net::OpenTimeout /
   Net::ReadTimeout / StandardError` rescue ladder, the same
   best-effort `JSON.parse(body)`, identical method-to-class dispatch
   table.
2. **Run timing** (all three) — `Time.now.utc` before and after the
   real call, then the same 10-line `Runner::ExecutionResult.new(...)`
   assembly with `duration_ms` / `started_at` / `finished_at`.

Both extracted into shared modules:

- **`Iface::HttpClient`** — single Net::HTTP wrapper. `request(method:,
  uri:, headers:, body:, timeout_ms:)` returns a `Response` struct
  with `status`, `body_text`, `body_json` (parsed iff parseable). Wire
  failures raise typed exceptions (`HttpClient::TimeoutError`,
  `HttpClient::RequestError`) so each caller maps to its own
  user-facing `error_type` label — http "timeout"/"http_error",
  llm "timeout"/"llm_error", etc.

- **`Iface::CallerTiming`** mixin — caller writes a private
  `perform_run(request)` returning a Hash; the mixin's `run(request)`
  wraps it in `Time.now.utc` measurement and packages the result as
  the `Runner::ExecutionResult` CallRunner expects. Caller no longer
  carries the timestamp-format / duration-math boilerplate.

Each caller is now focused on what's actually unique to its iface
type:

- **HttpCaller** (109 lines, was 160) — URL building, auth header
  attachment, 2xx-vs-non-2xx result classification.
- **LlmCaller** (213 lines, was 246) — per-provider request body
  shape (anthropic vs openai), per-provider header conventions
  (`x-api-key` vs `Authorization: Bearer`), response shape
  normalization to `{text, model, usage, stop_reason}`.
- **PostgresCaller** (147 lines, was 162) — only the timing wrapper
  changed; pg-specific transaction + SQLSTATE → error_type logic
  stays put.

LOC totals: 568 → 610 (+42). The refactor doesn't shrink absolute
lines, it concentrates knowledge: every new HTTP-talking caller
(slack, github, k8s, …) saves the ~70 lines of Net::HTTP +
ExecutionResult boilerplate. Phase 26's lazy-require pattern is still
free per caller.

13 new specs cover both modules: HttpClient (success path, header
forwarding, body_json fallback, timeout vs request-error mapping,
unsupported method, timeout_seconds floor + nil default — 10 specs),
CallerTiming (success, error preserved, duration measured, artifacts
default vs passthrough — 5 specs).

643 specs / 0 failures. Pure refactor — every existing caller spec
passes unchanged, end-to-end orchestrator integration unchanged.

### Phase 34: storage / disk / migration safety

Pre-launch audit found four storage-layer gaps. Phase 34 closes
them all without changing happy-path behaviour.

**34a — disk-full degrade-gracefully.** Every SQLite write went
through `DB#execute` raw — `Errno::ENOSPC` / `SQLite3::IOException`
/ `SQLite3::FullException` / `SQLite3::ReadOnlyException` propagated
unchanged and crashed the request handler. Worse: webhook ingestion
and `/v1/processes/:name/trigger` did TWO separate writes
(`enqueue` + `jobs.enqueue`) NOT in one transaction — a disk-full
between them left an orphaned `queued` run row that no worker could
pick up.

Changes:
- `Storage::DiskUnavailableError < Storage::StorageError`.
  `DB#execute` / `#execute_batch` translate the four exception
  classes above into it.
- `DB#healthy?` — quick `SELECT 1` + `BEGIN IMMEDIATE / ROLLBACK`
  write probe. SQLite `BUSY` counts as healthy.
- `App` rescues `DiskUnavailableError` from any handler: flips
  `@accepting = false`, returns 503 with body
  `{error: "storage unavailable", error_type: "storage_unavailable"}`.
- New `App#start_storage_probe` background thread (started by daemon
  entry). Polls `db.healthy?` every `PROUTERD_STORAGE_PROBE_SECONDS`
  (default 30); flips accepting back on when storage recovers.
- Webhook handler + `/v1/processes/:name/trigger` +
  `/v1/runs/:uid/replay` wrap their `orchestrator.enqueue` + jobs
  dispatch pair in `@store.db.transaction do … end`. Disk-full
  between the two writes now rolls both back atomically.

**34b — migration race.** Two daemons in a rolling deploy could
both enter the migration sweep within milliseconds of each other,
and existing migrations weren't idempotent (`CREATE TABLE jobs`
without `IF NOT EXISTS`) — recovering from a half-applied migration
was impossible.

Changes:
- `Migrations.run` wraps the entire sweep in `BEGIN EXCLUSIVE` with a
  30-second retry-with-backoff (`SQLite3::BusyException`). Two
  concurrent daemons serialise.
- `schema_migrations` gets `started_at` + `committed_at` columns
  (idempotent `ALTER` guarded by `PRAGMA table_info`). Pre-existing
  rows backfill `committed_at = applied_at`.
- Each migration writes `started_at` first, runs `up`, sets
  `committed_at` last — all inside the transaction.
- Sweep start: `DELETE FROM schema_migrations WHERE started_at
  IS NOT NULL AND committed_at IS NULL` — purges half-applied state
  from a prior crash so the migration re-applies. Safe because…
- All three existing migration bodies now use `CREATE TABLE IF NOT
  EXISTS` and `CREATE INDEX IF NOT EXISTS`. Re-running is a no-op.

**34c — ConfigStore atomicity regression spec.** Already atomic
since v0.1 (commit wraps both writes in `@db.transaction`). Added
`spec/prouterd/control_plane/config_store_atomicity_spec.rb` —
stubs `set_pointer` to raise mid-transaction, asserts no commit
row leaks. Future refactor that splits the writes will fail loud.

**34d — Postgres-as-storage-backend doc purge.** SQLite only, by
design. Removed the "Postgres adapter" out-of-scope bullet from
CLAUDE.md, the matching line from the README's "Out of scope"
list. All `interface postgres` mentions stay — separate iface
plugin.

5 new specs across 34a-34c. 649 specs / 0 failures.

### Phase 35: runtime safety — orphan kill, run timeout, secret context redact

**35a — orphan container kill at boot.** When a daemon crashes
mid-block, the docker container keeps running on the host. Recovery
swept run-rows but ignored containers. Now:
- `Runner::DockerStop` extracted as a shared module — DockerRunner's
  internal force_stop, `/v1/runs/:uid/cancel`, and Recovery all call
  the same two-stage SIGTERM-then-SIGKILL.
- `Recovery#sweep_orphan_containers` lists `Docker::Container.all`
  filtered by `label=prouterd.run_uid`, intersects against live run
  uids (queued/running runs OR runs with queued/locked jobs), kills
  the rest. Guarded by `DockerRunner.docker_available?` — installs
  without docker-api silently no-op.
- `Recovery::Result` extended with `containers_killed:` for
  structured-log reporting.

**35b — run-level wall-clock timeout.** Each block had a `timeout`,
queue had a `timeout`, but a long DAG × retries × slowly-dying block
could hang a run indefinitely. Now:
- New `process timeout <duration>` directive (parsed via
  `expect_duration`, rendered between `queue` and `shutdown`).
- Orchestrator's between-level loop computes
  `cap = process.timeout_ms || queue.timeout_ms ||
   PROUTERD_RUN_DEFAULT_TIMEOUT_MS || 6h`. Over-cap → kills in-flight
  containers via `Runner::DockerStop`, finalizes run as failed with
  `error_summary: "run_timeout: exceeded Nms wall-clock timeout"`.
- `kill_in_flight_containers` is the per-run analog of the orphan
  sweep, used both by the timeout enforcement and by the cancel
  handler (also refactored to call `DockerStop.force_stop` directly).

**35c — strict secret redaction in Context. BREAKING.** When a block
returned an `output_json` containing a secret value (e.g. because its
call-field templated `{{secret.X}}` and the block echoed it back),
the resolved value flowed unredacted into `Context[block.name]`,
into the persisted `run_steps.output_json` column, and into every
downstream block's `/prouter/input.json`. Now:
- New `Redactor#redact_json(value)` — recursive Hash/Array walk that
  applies the per-secret string scrubber at every leaf.
- Orchestrator's `execute_single_attempt` redacts `result.output_json`
  before persisting the step row AND before calling
  `update_context_with_output`. Same `[********]` mask as logs.
- Chained-auth pipelines that previously consumed a peer block's
  secret via `{{block.token}}` will now receive `[********]`. The
  fix: declare the secret on the consuming block too — every block
  resolves secrets independently from env / file via the secret
  resolver, no need to thread through Context.

5 new specs (orphan-container kill + 2 process-timeout + redact-context).
654 specs / 0 failures.

### Phase 36: API contract freeze + legacy purge + CLI ergonomics

**36a — /v1 contract spec freeze.** New
`spec/prouterd/api/v1_contract_spec.rb` pins the EXACT shape of every
documented endpoint via a strict `expect_keys` helper that fails on
ANY unexpected key (not just missing ones). 7 endpoints covered.
Future shape drift fails the suite immediately. Per Phase-32 user
decision: no Accept-header negotiation, no /v2 — breaking changes
go straight into /v1.

**36b — legacy purge.** Per «легаси сразу выкидывай»:
- core `run_summary` drops the legacy numeric `replay_of` field
  (was kept alongside `replay_of_uid` for back-compat). Web adapter
  + contract spec align on the single field.
- web `HttpApiAdapter#list_interfaces` drops the pre-Phase-32
  fallback that read flat `path`/`method`/`schedule`/`timezone`
  keys; reads only the plugin-driven `fields` hash now.
- `list_policies` drops `Array(p["retry_when"])` defensive wrap.
- `views/windows/interfaces.erb` drops the `if fields.empty?`
  flat-key fallback.

Web suite stays at 182/0 — the new shape is what the stub-core
fixture was already serving.

**36d — TTY autodetect for `prouter trigger` / `prouter replay`.**
When stdout is a TTY, the existing human-table format. When stdout
is piped, a single line of `JSON.dump({run_id, status, steps,
error})`. Same payload schema across both commands, so
`prouter trigger ... | jq …` works without parsing tables. New
`machine_output?` helper guards each output point.

**36e — `prouter validate <file> --against running`.** Beyond the
existing text-level `diff` command: structural diff over the parsed
AST::Document. Reports per section (interfaces / processes / routes
/ secrets / policies / queues) what's added, removed, or changed.
New `Util::SemanticDiff` produces the diff; `cmd_validate` runs
`Validator.validate` first, then diffs against `store.load_running`.
Honours `machine_output?` — JSON when piped, grouped human form on
terminal.

10 new specs across 36a/36d/36e + 5 SemanticDiff units. 671 specs /
0 failures. **Phases 34-36 close every pre-launch audit blocker.**

### Phase 37a: external-file form for text call-fields

`<call-field> file <path>` for `:command` / `:string` call-fields —
the parser inlines the referenced file's content at parse time.
Path resolves relative to the .prc file's directory; loaded via the
new `base_dir:` keyword threaded through `Parser.parse`. Keeps
multi-line prompts, system messages, JSON bodies in their own
files instead of bloating the .prc.

```
block summarize
 interface llm chat
 system file "prompts/summarize.system.md"
 prompt file "prompts/summarize.user.md.tmpl"
exit
```

Renderer side: `quote_string` / `escape_string` now encode
`\n` / `\t` / `\r` so multi-line content survives
render → DB → reparse round-trip (the lexer is line-oriented and
neither string form can span source lines).

5 new parser specs + 1 renderer roundtrip spec. 676 / 0.

### Phase 37b: `skip-when` block-level predicate

Block-level `skip-when <path> <op> <value>` directive. When the
predicate matches at run time, the block is skipped: a synthetic
`run_steps` row is written with `status = "skipped"` and
`output_json = {"skipped": true}`, the block's downstream is still
considered (skip is a routing pass-through, not a halt).

```
block fetch_slack
 interface http slack
 skip-when event.slack_thread_url eq ""
exit
```

Parser reuses `parse_match_at` (same single-line `<path> <op> <val>`
shape that `match` and `retry when` already use). Renderer emits
`skip-when` between `contract` and `secret` lines on the block.
Orchestrator evaluates the predicate during the level-build pass,
right after the existing `block.shutdown` check.

2 parser/renderer specs + 2 orchestrator specs (predicate matches /
predicate misses). 681 / 0.

### Phase 37c: `vars` overlay on a block

Sub-section inside a block body — local-name overlay for templating
its call-fields. Each line is `<name> <value>` where the value is
itself a template. The orchestrator resolves the var values against
the regular scope first, then exposes them at top level under their
local names while templating the block's call-fields.

```
block analyze
 interface llm chat
 prompt file "prompts/analyze.user.md.tmpl"
 vars
  evidence  "{{event.body.evidence}}"
  iteration "{{previous.attempt}}"
 exit
exit
```

Resolution is single-pass against the base scope — `b "{{a}}"` does
not see `a`, both see only the underlying context. This avoids
ordering surprises.

2 parser specs + 1 renderer roundtrip + 2 orchestrator specs.
686 / 0.

### Phase 37d: process-level `thread-id` for per-entity scoping

Process-level `thread-id "<template>"` derives a stable id from
the input event at trigger time, persisted into the new
`runs.thread_id` column (migration 0004) and indexed for filtered
list queries. An empty rendered template is treated as nil so an
absent field doesn't pin all runs to thread_id="".

```
process per_ticket
 thread-id "{{event.ticket}}"
 ...
exit
```

Wiring:
- `Storage::Run` carries `thread_id`.
- `Repositories::Runs#list_runs` accepts a `thread_id:` filter.
- `/v1/runs?thread_id=...` filter; `run_summary` shape gains
  `thread_id` (contract spec updated).
- `show runs [thread <id>] [process <name>]` filters in the shell.

Migration runner now accepts a Proc-bodied migration too — needed
because SQLite has no `ALTER TABLE ADD COLUMN IF NOT EXISTS`, and
a half-applied retry would otherwise hit "duplicate column". The
0004 body inspects `PRAGMA table_info(runs)` before adding.

4 thread-id orchestrator specs + parser + renderer roundtrip +
v1-contract update. 692 / 0.

### Phase 37e: reflection-loop retry — output predicates + feedback

`retry when` predicates now also evaluate against the attempt's
`output_json` under the `output.*` namespace. A successful attempt
whose output flags a verifier-fail is treated as a logical failure
and re-fired (subject to attempts/backoff). Reaching max attempts
on a still-matching success surfaces as `error_type =
retry_when_unsatisfied`, so the run terminates as failed rather
than silently returning the last bad output.

New `retry feedback <output-path> into <local>` directive copies a
path out of the prior attempt's output into the next attempt's
`previous.<local>` overlay. Reflection loops can then template
`{{previous.feedback}}` to carry verifier notes forward.

```
policy reflect
 retry attempts 3
 retry when output.verify eq "fail"
 retry feedback output.verify.notes into feedback
exit
```

The unified retry rule:
- No `retry when` matches → retry on failure (legacy).
- Any `retry when` match → retry, regardless of success/failure.
- Failure with no match → terminal.
- Success with no match → success.

`Runner::ExecutionResult#dup_as_failure` reshapes a
predicate-matched success into the `retry_when_unsatisfied` failure
without losing output_json/artifacts.

3 reflection runtime specs + 2 parser + 1 renderer roundtrip.
698 / 0.

### Phase 37f: per-run LLM token usage accumulator

After each block attempt, the orchestrator inspects the result's
`output_json["usage"]` envelope (LlmCaller normalises both Anthropic
and OpenAI providers to {input_tokens, output_tokens}; OpenAI's
{prompt_tokens, completion_tokens} also accepted as a fallback) and
accumulates into the new `runs.tokens_in` / `runs.tokens_out`
columns (migration 0005). Surfaced in `/v1/runs[/<uid>]` summary
(contract spec updated) and `show run`.

Foundation for cost-bounded retry policies and per-thread cost
reporting; price-table-driven `cost_usd` is deferred until a real
price-table source materialises.

3 runtime specs + contract update. 701 / 0.

### Phase 37g: pause + resume primitive

A block can declare `pause "<reason>"` instead of `interface ...`.
When the orchestrator hits a pause block it writes a synthetic
`run_steps` row with `status="paused"`, persists the run context,
and sets `runs.status="paused"` — execution halts there. New
`prouter resume run <uid> [--value <json> | --value-file <path>]`
loads the run's pinned commit, fills the paused step's output_json
with the supplied value (default `{}`), seeds the run context with
`<paused_block_name> => value`, and re-enters the orchestrator at
the blocks immediately downstream of the paused one.

```
block approve
 pause "ok to ship?"
exit
```

The same run uid persists across pause/resume — one logical run,
two execution phases. Pause-blocks are mutually exclusive with
`interface` (validator + parser); a pause block at a terminal
position succeeds immediately on resume. Run status enum gains
"paused"; step status enum gains "paused" too. The placeholder
"waiting" status (introduced in earlier phases but never emitted)
is removed.

3 runtime specs + 3 parser specs + 1 renderer roundtrip + CLI
smoke. 708 / 0.

### Phase 37h: codex_cli / claude_cli LLM providers

`provider codex_cli` / `provider claude_cli` on `interface llm`
shell out to a local CLI binary whose authentication lives in a
subscription token on disk — bypasses per-token API pricing for
high-volume LLM workloads. Authentication is not configurable via
the DSL: the binary handles it.

```
interface llm codex
 provider codex_cli
 model gpt-5-codex
 home /Users/u/.codex             # HOME for the subprocess (token state)
 sandbox read-only                 # passed via -s
exit
```

Driver lives in `Iface::LlmSubprocess`: spawns
`<binary> exec --json -m <model> [-s <sandbox>]`, pipes the prompt
to stdin, reads JSONL events from stdout. Aggregates text out of:
`item.completed` (codex), `message_delta` (claude), bare `text`/
`content`. Sums `usage.input_tokens` / `output_tokens` (with
`prompt_tokens` / `completion_tokens` as fallback). Returns the
canonical `{text, model, usage, stop_reason}` shape identical to
the HTTP providers, so downstream blocks and the per-run usage
accumulator (Phase 37f) work unchanged.

Binary resolution: `binary <path>` field → `PROUTERD_<PROVIDER>_BIN`
env → `codex` / `claude` on PATH. Missing-binary surfaces as
`error_type=missing_dependency`; non-zero exit as `llm_error`;
deadline exceeded as `timeout`.

Validator rejects `auth bearer secret` on subprocess providers
(authentication isn't theirs to configure) and `binary`/`home`/
`sandbox` on HTTP providers (no meaning).

4 driver specs (codex/claude shape, missing binary, non-zero exit).
712 / 0.

### Phase 37i: block-level `fan-out from <path> into <process>`

After a block succeeds, the orchestrator walks the named array path
in its (redacted) output_json and enqueues one new run of the named
process per element. Each element becomes the child run's input
event; children carry the parent's run id as `parent_run_id` so
`/v1/runs?...` can query the lineage. When the target process
declares a `thread-id` template, child runs get their thread_id
resolved against the per-element event — making per-entity scoping
work end-to-end.

```
process poller
 block search
  interface http jira
  fan-out from issues into analyze_ticket
 exit
exit

process analyze_ticket
 thread-id "{{event.key}}"
 block do_work
  ...
 exit
exit
```

Children are enqueued only — orchestrator doesn't drive them
synchronously. The daemon's worker pool / scheduler picks them up.
Path-not-array and missing-target-process cases log a system
message and skip; non-Hash array elements get wrapped into
`{value, index}` so the child sees a Hash event.

Validator rejects fan-outs targeting an undeclared process. No
dedupe / rate-limit / map clauses yet — the minimum primitive
ships first.

3 runtime specs + parser + renderer roundtrip + validator
coverage. 717 / 0.

### Phase 37j: declarative `parallel <name>` container

Process-level `parallel <name>` section groups N child blocks that
run concurrently, with a synthesized barrier block carrying the
group's name so downstream routes (`route evidence analyze`) work
the same as for a single block.

```
process p
 parallel evidence
  join-strategy all-best-effort     # default: all-required
  block fetch_jira    ... exit
  block fetch_slack   ... exit
  block fetch_sentry  ... exit
 exit

 block analyze
  command "succeeded={{evidence.succeeded}}"
 exit

 route evidence analyze
exit
```

Mechanism: at parse time the section expands into the group's
member blocks added to `process.blocks`, plus a synthesized barrier
block (also on `process.blocks`) named after the group, plus
synthesized routes from each member to the barrier. Validator
relaxes its single-incoming check for barrier blocks. The
orchestrator special-cases barriers in `execute_single_attempt` —
no runner dispatch, just a step row + an aggregated output of
`{members:{...}, succeeded:[...], failed:[...], join_strategy}`
seeded into context under the group name.

Join strategies:
- `all-required` (default): default route on-failure="stop" so any
  member failure aborts the run before the barrier even fires.
- `all-best-effort`: synthesized routes get on-failure="continue",
  and on_failure_for now also consults a failed block's outgoing
  route to a barrier — survivors flow through, failures appear in
  `output.failed`.

`first-success` / `first-completed` deferred until a real driver.

Renderer round-trips the source form (children inside the
`parallel` body, no synthesized routes leaked).

3 runtime specs + 3 parser + 1 renderer roundtrip. 724 / 0.

### Phase 37k: tool declarations + agentic-block DSL surface

DSL surface for multi-turn tool-use on `interface llm` blocks.
Top-level `tool <name>` declares a callable; block-level `agentic
on`, `allowed-tools <list>`, `tool-call-limit <int>` opt the LLM
block into the (still-pending) multi-turn loop.

```
tool jira_search
 description "Search Jira issues by JQL."
 args jql, max
 returns issues
 implementation interface http jira call get
exit

block deep_dive
 interface llm codex
 prompt file "prompts/deep_dive.user.md"
 agentic on
 allowed-tools jira_search, repo_grep
 tool-call-limit 12
exit
```

Validator:
- tool implementation must reference a declared interface
- `agentic on` requires `interface llm <name>`
- `allowed-tools` entries must reference declared tools

Renderer round-trips the form. Parser/AST/validator/renderer ship
this turn; the orchestrator runtime (multi-turn loop, native
provider tool API integration, tool dispatch via the iface plugin
system) is deferred — running an agentic block today returns
`error_type=agentic_not_implemented` with an actionable message.

3 validator specs + 2 parser + 1 renderer roundtrip. 730 / 0.

### Phase 37l: `interface local_repo` (whitelisted, sandboxed git)

New outbound interface plugin: read-only access to a controlled
set of local git checkouts under a single root directory. Bypasses
the need to grant agentic blocks (or any block) raw shell access
when all they need is to look at code.

```
interface local_repo workspace
 root /opt/atp/checkouts
 whitelist vosio/app, vosio/api-gateway
 default-branch develop
 sandbox read-only
 max-file-size 500KB
exit

block fetch_repo
 interface local_repo workspace
 call grep
 repo vosio/app
 pattern "TODO\\(release-blocker\\)"
exit
```

Three calls: `gather` (commit log over a range), `read` (file
content), `grep` (pattern, optional path scope). Output JSON shape:
`{commits|matches|content+path+size}` per call.

Security:
- `repo` MUST be in the whitelist.
- The resolved repo dir MUST live under `root`.
- User-supplied `path` is canonicalised under the repo dir;
  traversal segments rejected before subprocess invocation.
- `git -C <repo>` is invoked with explicit argv (no shell), so
  user-influenced strings can't smuggle flags or shell metacharacters.

Validator enforces absolute `root` and a non-empty whitelist.

6 caller specs covering whitelist, traversal, read, grep (hit/miss),
gather. 736 / 0.

### Phase 37m: agentic multi-turn tool-use runtime

The agentic-block runtime stub introduced in Phase 37k is replaced
by a real driver. `Iface::LlmAgentic` runs an Anthropic-flavoured
multi-turn loop against `/v1/messages` with a `tools` array; on
each `stop_reason=tool_use` the driver invokes a per-block
dispatcher, appends the result as a `tool_result` content block,
and re-fires the next turn until the model returns plain text or
`tool-call-limit` is hit (then `stop_reason=max_turns`).

The orchestrator's `execute_agentic_block` builds the dispatcher
as a closure capturing the document + run + parent env; each
tool_use is mapped to a synthesized `RunRequest` whose
`execution_type` is the tool's implementation iface and whose
`type_fields` merge `iface.type_fields` + `tool.implementation.call`
+ the LLM-provided args. Dispatch goes through the same
`CallRunner` ordinary blocks use — tools are first-class outbound
calls, not a parallel pipeline.

Output JSON shape matches an ordinary LLM block plus
`tool_calls:[{name,input,output}]` and `turns:N`; the per-run token
usage accumulator (Phase 37f) sees both turns and aggregates
correctly. Persisted step row, redaction, and context-update all
flow through the standard pipeline.

Validator now also rejects `agentic on` on a non-anthropic
interface at apply time, so configs that the runtime can't drive
fail earlier than first trigger. OpenAI / subprocess providers are
deferred — their tool surfaces differ enough to deserve their own
drivers.

4 driver specs (tool-use turn, max-turns ceiling, dispatcher-error
propagation, HTTP non-2xx) + 2 orchestrator integration specs.
742 / 0.

### Phase 38a: `prices <provider>` + per-run `cost_usd` accumulator

New top-level declaration carries per-million-token rates per
model:

```
prices anthropic
 model claude-haiku-4-5-20251001 in 0.25  out 1.25
 model claude-opus-4-7           in 15.00 out 75.00
exit
```

After each LLM block attempt the orchestrator looks up the matching
{provider, model} in the document's prices tables and bumps
`runs.cost_usd` (migration 0006) alongside `tokens_in` /
`tokens_out`. Missing prices table or model → 0 cost; token
telemetry still records.

Surface: `/v1` `run_summary` gains `cost_usd` (rounded to 6
decimals); contract spec updated. AST::Prices + Entry; parser +
renderer round-trip. New `expect_decimal` helper.

3 specs (parser + runtime accumulator). 769 / 0.

### Phase 38b: cost guardrails

Two cost-aware kill switches built on Phase 38a's accumulator.

- Block-level `max-cost-usd <decimal>`: after each attempt, refresh
  `runs.cost_usd`; if it crossed the cap, reshape the result into a
  terminal failure with `error_type=cost_cap_exceeded`. Retries
  don't keep burning budget.
- Policy-level `retry stop-on <path> <op> <value>`: kill switch
  evaluated against live run state after every attempt. Today the
  exposed namespace is `run.{cost_usd, tokens_in, tokens_out}`.
  Match → break the retry loop regardless of attempts left.

```
policy budget_aware
 retry attempts 5
 retry when output.flag eq "fail"
 retry stop-on run.cost_usd gt 2.50
exit
```

Both refresh the run row from the DB so cost_usd reflects this
attempt's accumulator bump.

2 runtime specs. 771 / 0.

### Phase 38c: `prouter validate` lint alias + `mcp_tool` sugar

`prouter validate <file>` without `--against` falls through to the
existing `prouter check` lint path — the canonical CLI verb for
docs and CI hooks. `--against running` keeps the deeper diff form
unchanged.

`mcp_tool <name> ... exit` is parser sugar for the common case
where an integration is one shell-script with an `op` discriminator
and JSON I/O. Three declaration blocks at the top of an .prc
collapse into one:

```
mcp_tool jira
 description "Jira API microservice."
 args op, key, jql, max
 exec "./integrations/jira-api.sh"
 cwd /opt/atp
exit
```

Expands at parse time into an `interface shell jira` + `tool jira`
pair pointing at it. No new runtime. 772 / 0.

### Phase 38d: `fan-out` enrichment — map / dedupe / rate-limit

Phase 37i shipped the minimum primitive (one child per array
element). Phase 38d adds projection, idempotency, and back-pressure
on the same line:

```
fan-out from issues into analyze_ticket
 map ticket from issue.key
 map labels from issue.labels filter starts-with("repo:") strip-prefix
 dedupe by ticket window 24h when prior-run.status eq "success"
 rate-limit 1/5s
exit
```

`fan-out from X into Y` opens an optional sub-section. Body:

- `map <name> from <path> [filter starts-with("<prefix>") strip-prefix]`
  projects fields onto the child event. With no maps the element
  passes through (Hash) or wraps `{value, index}`. With maps, only
  projected fields appear — per-child events stay minimal.
- `dedupe by <field> window <duration> [when prior-run.status eq <s>]`
  skips a child when an earlier run of the same target process with
  the same `thread_id` ran within the window. Honours the existing
  `thread_id_template` / fan-out thread-id derivation.
- `rate-limit N/window` spaces children N-per-window via the
  durable jobs queue's `available_at`.

The orchestrator now also enqueues an `execute` job per child run
(previously fan-out only created run rows; the worker pool would
never pick them up without a job).

Renderer round-trips the long form with body when any enrichment
clause is set, falling back to the single-line form otherwise.

774 / 0.

### Phase 38e: `auto-pull` for `interface local_repo`

`auto-pull <duration>` declares a background `git pull --ff-only`
cadence per whitelist entry. The Scheduler tick walks local_repo
ifaces, fires the pull on a detached thread when cadence elapses.
Failures logged, never block — the next tick retries.

Operator perspective: drop the external cron, declare cadence once
in the .prc, fleet-deploy without a separate stretchy contract.

777 / 0.

### Phase 38f: `agentic on` for codex_cli / claude_cli

`Iface::LlmAgentic.run` now dispatches by provider:

- **HTTP (anthropic)** — existing `/v1/messages` tools loop.
- **Subprocess (codex_cli / claude_cli)** — single persistent
  process per agentic block, JSONL over stdin/stdout:

      in:  {"role":"user","content":"<prompt>","tools":[...],"system":"..."}
      out: {"type":"item.completed","item":{"type":"message",...}}      → text
      out: {"type":"item.completed","item":{"type":"function_call",...}}→ tool
      in:  {"type":"function_call_output","call_id":"...","output":"..."}
      out: {"type":"turn.completed","usage":{...},"stop_reason":"..."}  → end

Same dispatcher closure used by both transports — tool dispatch
goes through the orchestrator's existing CallRunner. Per-run token
usage accumulator (Phase 38a) sees both transports. Validator +
`execute_agentic_block` allow-list now includes the subprocess
providers; OpenAI HTTP function-calling deferred (different shape).

Recogniser methods `extract_event_text`, `extract_event_function_call`,
`turn_completed?` are split out so the JSONL shape can be widened
when the real CLI protocol shifts.

5 driver specs (added subprocess loop with fake CLI). 778 / 0.

### Phase 38h: syslog-style daemon logging

Replaces the ad-hoc `<ts> LEVEL prouterd: <msg> k=v` format with
the canonical syslog shape:

    May  8 14:23:01.234: %DAEMON-6-STARTING: daemon starting bind=127.0.0.1 port=8080

Every emit() supplies a `facility` (uppercase grep key — `DAEMON`,
`RUN`, `STORE`, `SCHED`, `WORK`, `WEBHOOK`, `RECOV`, `CONFIG`,
`SECRET`, `API`) and a `mnemonic` (short uppercase tag — `STARTING`,
`HMAC_FAIL`, `ACCEPTED`, `RUN_CRASHED`, etc). Severity is the standard
0–7 syslog scale; new `notice` (5) level added for config / lifecycle
events that aren't errors but matter.

Process-singleton ring buffer caches the last 1000 entries.
`show logging last <N> [severity <0-7>] [facility <NAME>]` reads from
it — same surface as router-CLI `show logging`. The same line goes to stdout
for journald / `docker logs` capture.

New lifecycle/security log lines: `WEBHOOK-ACCEPTED`,
`WEBHOOK-HMAC_FAIL`, `RUN-COMPLETED`, `RUN-FAILED`, `RUN-CANCELED`,
`RUN-PAUSED`, `RUN-RESUMED`, `SECRET-MISSING`, `CONFIG-APPLIED`,
`CONFIG-SAVED`, `CONFIG-ROLLBACK`. Existing 24 callsites migrated to
the new format with stable facility/mnemonic pairs.

Mnemonic catalog at `docs/log-messages.md` documents every emitted
line: severity, format template, meaning, action.

794 / 0.

### Phase 38i: BREAKING — `/v1` error envelope frozen

Every 4xx/5xx response from `/v1`, `/i/<webhook>`, and the routing
layer now returns the canonical shape:

    { "error": { "code": "<stable_string>",
                 "message": "<human>",
                 "details"?: <any> } }

Previously, three forms coexisted: bare `{error: "..."}`,
`{error: msg, line: N}`, and `{error: "...", details: [...]}`. The
`v1_contract_spec` froze happy paths only — error shapes drifted
silently. New `error envelope` describe-block in that spec asserts
exact shape on the most common error paths (404 not_found, 400
invalid_dsl/bad_json/invalid_argument, 422 validation_failed/
unprocessable, 401 unauthorized, …).

`code` is the contract-stable identifier clients should branch on;
the daemon will never rename one without a /v1 break note here.
`message` is human-readable. `details` is optional and shape-flexible
(the validator emits an Array of strings; the parser emits a Hash
with `line`).

Stable codes today: `not_found`, `invalid_dsl`, `validation_failed`,
`bad_json`, `invalid_argument`, `missing_body`, `unauthorized`,
`forbidden`, `conflict`, `gone`, `payload_too_large`, `rate_limited`,
`internal_error`, `unavailable`, `storage_unavailable`,
`method_not_allowed`, `unprocessable`, `secret_unresolved`, `bad_path`.

`Auth.check_bearer` now returns `[status, code, message]` triples
(was `[status, message]`); call sites updated.

The canonical helper lives in V1 / App / WebhookHandler:
`json_error(status, code, message, details: nil, headers: nil)`.

Migration impact: any client (curl scripts, prouterd-web adapters,
custom dashboards) that read `body["error"]` as a string must now
read `body["error"]["message"]`. The `prouterd-web` adapter already
handles the new shape via `RpcDispatcher#forward_json`'s envelope
parsing, but external integrations need a one-line fix.

834 / 0 (was 826 + 8 new error-envelope contract specs).

## Status

- 38 phases shipped, one git commit per phase
- 834 RSpec specs, 0 failures
- Two binaries: `prouter` (operator CLI) + `prouterd` (long-running daemon)
- Default install runs on Ruby stdlib only (`Open3`, `Net::HTTP`); the
  shell / http / llm / webhook / manual interfaces all work out of the
  box. `interface docker` / `postgres` / `cron` are explicit
  `gem install` away.
- All v0.1 acceptance criteria + production hardening + IPC +
  contracts + router-CLI compatibility + binary split + typed
  artifacts + unified interface model + smart retries + opt-in heavy
  dependencies + backtick raw strings.
- End-to-end smoke-tested against real Docker + Puma + cron + shell exec
- Distributable as a Docker image (`docker build . && docker run`)
- Pluggable interfaces: third-party gems can register a new
  inbound/outbound `interface` type without forking the core.
