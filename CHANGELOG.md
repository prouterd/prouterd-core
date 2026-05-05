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

## Status

- 31 phases shipped, one git commit per phase
- 627 RSpec specs, 0 failures
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
