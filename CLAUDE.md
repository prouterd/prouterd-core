# Notes for Claude (and other future contributors)

This file is the maintenance manual: how the codebase is organized, why
certain non-obvious choices were made, and the gotchas that already cost
debug time once.

## Mental model

Two layers, talking to each other through small interfaces:

1. **Control plane** — config: parser, validator, renderer, ConfigStore
   (commit/rollback/write_memory). Everything here is pure data + SQLite.
2. **Data plane** — runtime: Orchestrator, Runner adapters, ArtifactStore,
   Scheduler, webhook handler. Sees the AST::Document, drives containers.

The shell is the operator surface that bridges both — modes for control
plane (config edits), commands for data plane (trigger, replay, cancel).

A new feature usually slots cleanly into one of:

- DSL → `lib/prouterd/config/`
- Persistence → `lib/prouterd/storage/`
- Operator surface → `lib/prouterd/shell/`
- Execution → `lib/prouterd/runtime/`
- HTTP / external → `lib/prouterd/api/`
- CLI plumbing → `lib/prouterd/cli/main.rb`

## Adding a new field to the DSL

1. Update [`lib/prouterd/config/ast.rb`](lib/prouterd/config/ast.rb) — add the attribute to the relevant node class.
2. Update [`lib/prouterd/config/parser.rb`](lib/prouterd/config/parser.rb) — add a case branch in the appropriate
   `apply_X_field` method (or `parse_X_field` for sections that already
   use that name). Reuse the helpers (`expect_token_count`,
   `expect_duration`, `expect_identifier`, etc.).
3. Update [`lib/prouterd/config/renderer.rb`](lib/prouterd/config/renderer.rb) — emit the field with the right
   indentation. Call `quote_string` for any value that might contain
   whitespace or quotes.
4. Update [`lib/prouterd/config/validator.rb`](lib/prouterd/config/validator.rb) if the new field has
   cross-section invariants (refs, ranges, mutual exclusivity).
5. Add a test in `spec/prouterd/config/parser_spec.rb` that covers
   parsing AND a roundtrip through the renderer.

The Section sub-modes in the shell pick up new fields automatically
because they override `apply_field` to delegate to the parser's
`apply_X_field` methods. If your field is on `Process` / `Block` /
`ProcessRoute` / `GlobalRoute` you might also want a typed handler in
the corresponding mode for auto-completion or special UX, but the
default fall-through works.

For block fields, decide whether the field is a **call-field**
(per-block argument to the outbound interface — `command` for docker,
`body` for http, etc.) or a **common block field**:

- **Call-field** (per-call args templated at runtime): declared on the
  iface plugin class via `call_field :foo, kind: :...`. Each iface
  plugin owns two field schemas: `field` for the interface-config body
  (image, base url, …) and `call_field` for the block body (command,
  query string, …). One line in one plugin file, no edits to
  parser/renderer/validator.
- **Common block field** (produces, timeout, retry, contract, secret,
  enable/disable): handled in `parse_block_field` and rendered after
  the `interface <type> <name>` line. The 5-step recipe above applies
  for these.

Note: blocks no longer have an `input` or `output` directive. Inputs
flow through `{{path}}` templating (Util::Templater) inside call-field
values, and outputs are auto-stored at `context[block.name]`. There is
no `block.execution_type` / `block.image` / `block.command` accessor
either — the block carries an `interface_ref` plus a `type_fields`
hash whose schema is owned by the referenced iface plugin.

## Barriers and grouping constructs (parallel / merge)

Two in-process containers synthesize a barrier block + member→barrier
routes. Both produce a `Block` with `barrier_for` (member names) and
`barrier_join_strategy`; they're distinguished by `barrier_kind`:

- `:parallel` — `parallel <name> ... block X ... block Y ... exit`
  declares member blocks inline. The parser guarantees members are
  same-level siblings; the scheduler eager-enqueues the barrier as
  soon as one member's route passes (correct because all members
  finish in the same BFS level).
- `:merge` — `merge <name> / from a, b, c / strategy <s> / exit`
  references existing sibling blocks. Members may live at different
  BFS depths. `Orchestrator#and_style_merge_barrier?` defers
  enqueuing AND-style barriers (`all-required` / `all-best-effort`)
  until every member is in `executed`; `any` strategy keeps the
  eager enqueue.

`BlockExecutor#execute_barrier_block` reads `barrier_join_strategy`
and produces the strategy-specific output shape (members/succeeded/
failed for AND, winner/output for `any`, merged for `merge-children`).

If you ever add a third grouping construct, mirror this split:
  - source-form record on `Process` (`@<kind>_groups`)
  - synthesized barrier with a new `barrier_kind` value
  - renderer skips the synth barrier + member→barrier routes by
    consuming the group records
  - if members can span BFS levels, gate readiness in the scheduler

## Adding a new shell command

1. Add the dispatch entry in the relevant mode's `commands` hash
   (`lib/prouterd/shell/modes/*.rb`). The base `Mode#execute` does
   router-style unique-prefix expansion against `commands.keys` for free —
   `sh run` resolves to `show running-config` without any extra wiring.
   Inside multi-word commands (`copy running-config startup-config`),
   call `match_keyword?(tokens[i].value, "expected")` instead of `==`
   so abbreviated keywords (`co ru st`) work too.
2. Implement `cmd_<name>(tokens, session, out, err)`. Raise `CommandError`
   for user-visible errors; the shell catches and prints with `% ` prefix.
3. Update the mode's `cmd_help` text.
4. If the command is also useful from the CLI, add a top-level `cmd_<name>`
   to `lib/prouterd/cli/main.rb` and a `when "..." then cmd_<name>` line in
   `run`.

## Adding a new storage migration

`lib/prouterd/storage/migrations.rb` holds an ordered array of `Migration`
objects with `version` and `up` SQL. **Never edit an applied migration**
— append a new one. Tests use `:memory:` SQLite so they always start
empty; a real DB tracks applied migrations in `schema_migrations` and
runs only the pending ones on `DB.open`.

## Conventions

- **No Rails.** Pure Ruby + SQLite + Rack. Keep it that way.
- **Thread safety.** The orchestrator runs blocks in parallel via
  `Thread.new`. DB writes go through `db_mutex`; Context get/set goes
  through `ctx_mutex`. Runner.run() must run OUTSIDE both — that's the
  whole point of the design.
- **Secret hygiene.** Anything touching log content, error_summary, or
  step.error_message MUST run through `Redactor`. The orchestrator builds
  a per-run redactor from every secret in the document, not just the
  ones a particular block references.
- **Public API of Parser.** The `apply_X_field` methods are publicly
  exposed at the bottom of the class for shell reuse. Don't move them
  back into private without a separate path for the shell.
- **Error types.** Use `Config::*Error` for parser/validator errors,
  `Shell::CommandError` for user-visible CLI errors, `Storage::StorageError`
  for persistence, `Runtime::TriggerError` for orchestration. Never
  raise `RuntimeError` directly.
- **Iface dispatch is plugin-driven.** The set of legal `interface
  <type> <name>` types is whatever's currently registered in
  `Iface::Registry`. Plugins declare `direction :inbound` (webhook,
  cron, manual) or `:outbound` (docker, shell, http, mcp). Blocks may
  only reference outbound interfaces with `block_callable true`
  (default); runtime-only outbound integrations such as MCP use
  `block_callable false` and are reached through their own runtime path.
  Global routes wire inbound interfaces to processes. Parser, validator,
  renderer, `show`, tracer, CallRunner, and CLI all iterate over the
  registry and the plugin's declared `field` / `call_field` schemas —
  they hardcode no type names.
- **Logging is structured.** Build one `Prouterd::Logger` in `cmd_serve`
  and thread it through all components via `logger:` kwarg. Format is
  `<ts> <LEVEL> prouterd: <message> k=v k=v…` — single-line, grep-able,
  no JSON unless a value contains spaces/`=`. Do NOT use `puts` /
  `@output.puts` in `lib/` — **except in `lib/prouterd/shell/`**, where
  `@output.puts` IS the operator-facing API (shell renders tables and
  human-readable replies on stdout). Everywhere else in `lib/`, route
  diagnostic output through the structured logger; tests pass
  `Prouterd::NullLogger.new`.
- **Operational knobs go through ENV.** New behavior that an operator
  might want to tune (cap, timeout, path) reads
  `PROUTERD_<UPPER_SNAKE>` with a sensible compile-time default. Never
  put operational tunables in `.prc` files — those are for *intent*,
  ENV is for *deployment*. Document the new var in README's "Production
  env vars" table.

## Adding a new interface type

An iface type is one plugin file (+ a caller class for block-callable
outbound types).
**Nothing else in the codebase needs to change** — parser, validator,
renderer, show, tracer, CallRunner, and CLI all discover the new type
through `Iface::Registry`.

### Inbound vs outbound

- **Inbound** (webhook, cron, manual): triggers runs. The plugin
  declares `direction :inbound` and `field :foo, ...` for the
  interface body. The plugin needs no caller — inbound interfaces are
  driven by the daemon (Scheduler / webhook handler / `trigger`
  command). They have no `call_field` schema.
- **Outbound** (docker, shell, http): blocks reference these via
  `interface <type> <name>` and supply per-call args
  (`command`, `query`, `body`, ...). The plugin declares
  `direction :outbound`, both `field` (interface-config schema) and
  `call_field` (per-block-call schema), and `caller "ClassName"`.
- **Runtime-only outbound** (mcp): the daemon/runtime calls the
  integration, but ordinary process blocks do not dispatch to it
  directly. Declare `direction :outbound` plus `block_callable false`
  and omit `caller`; wire it through the specific runtime feature
  instead.

### 1. Write the caller (block-callable outbound only)

Implement `#call(request) -> ExecutionResult`. Read interface-config
fields and call-fields from `request.type_fields["foo"]` (CallRunner
templates `{{path}}` substitutions before dispatch). Output JSON,
artifacts, exit code → `ExecutionResult`.

```ruby
# lib/prouterd/iface/lambda_caller.rb
module Prouterd::Iface
  class LambdaCaller
    def call(request)
      arn = request.type_fields["arn"]
      payload = request.input_json
      # ... invoke AWS Lambda, capture result, build ExecutionResult ...
    end
  end
end
```

### 2. Write the plugin

Subclass `Iface::Plugin`, declare type + direction, list the fields,
point at the caller class. One file, no boilerplate elsewhere.

```ruby
# lib/prouterd/iface/plugins/lambda.rb
require_relative "../plugin"
require_relative "../registry"

module Prouterd::Iface::Plugins
  class Lambda < Prouterd::Iface::Plugin
    type "lambda"
    direction :outbound

    field :arn,    kind: :string, required: true, description: "Lambda function ARN"
    field :region, kind: :string, default: "us-east-1"

    call_field :payload, kind: :string

    caller "Prouterd::Iface::LambdaCaller"
  end

  Prouterd::Iface::Registry.register!(Lambda)
end
```

Field kinds:

- `:string` — single token (word or quoted string)
- `:enum` — must match `enum:` list
- `:command` — joins all remaining tokens, always quoted in canonical render
- `:env_pair` — `KEY value` accumulating into a Hash<String,String>
- `:env_forward` — single `KEY`, accumulating into an Array<String>
  (whitelist of env var names to pass through from the daemon env)
- `:secret_ref` — single `<NAME>`, accumulating into an Array<String>;
  `BlockExecutor#build_env` resolves each name through `secret <NAME>`
  declarations and exposes the value under env key `<NAME>` (no
  hardcoded type-name dispatch — plugin-driven via `Iface::Registry`)
- `:path`, `:http_method`, `:auth_bearer` — used by webhook/http plugins

Pass `caller` as a class OR a String class name. Strings are resolved
lazily — useful when the caller pulls in a heavy dependency (e.g.
`docker-api`) that you only want loaded when the iface is actually used.
Omit `caller` only for `block_callable false` runtime-only integrations.

### 3. Make Prouterd load it

Built-in plugins are required from `lib/prouterd/iface.rb`. Third-party
plugins (in a separate gem) just `require` their plugin file at boot;
the `Registry.register!` call at the bottom of the file does the rest.

That's it. `prouter check`, `prouter render`, `prouter shell`, `prouter
trigger`, and the daemon all immediately understand `interface lambda
<name>`.

## Gotchas (real bugs caught the hard way)

### `String.new` is binary by default

```ruby
s = String.new  # => Encoding::ASCII_8BIT
```

The lexer originally did this. Strings flowed into SQLite as BLOB rather
than TEXT, and parameterized queries (`WHERE uid = ?`) returned zero rows
even when bytes matched. **Always**:

```ruby
String.new(encoding: Encoding::UTF_8)
```

This is currently fixed in [`lib/prouterd/config/lexer.rb`](lib/prouterd/config/lexer.rb).

### Rack 3 wants Enumerable bodies

`[200, headers, "body"]` works under rack-test but explodes under real
Puma with `undefined method 'call' for "...":String`. Wrap in arrays:
`[200, headers, ["body"]]`. The webhook handler had this issue in
non-success paths only — caught at smoke time.

### Shell `command "..."` quoting

Block call-field command strings in `.prc` go through:

1. Lexer — two string forms:
   - `"..."` double-quoted: `\"` → `"`, `\\` → `\`, `\n`/`\t`/`\r` escapes
   - `` `...` `` backtick raw: every byte literal, no escape processing
2. Stored verbatim in `block.type_fields["command"]`
3. **Renderer must quote them** — otherwise apply→reload loses spaces
   and quotes. The renderer iterates the iface plugin's `call_fields`
   and applies `quote_string`. `quote_string` automatically picks the
   backtick form when the value contains `"` or `\` and no embedded
   `` ` `` — exactly the case where double-quoted form would force
   `\\\"` escape pyramids.
4. Orchestrator runs the value through `Util::Templater` for `{{...}}`
   substitution, then hands the templated string to the caller.
5. ShellRunner uses `Shellwords.split` to break into argv; DockerRunner
   does the same and passes through to the container's `sh -c`.

For both shell AND docker blocks: writing `/prouter/output.json` is
**optional**. If `exit_code == 0` and the file is missing, the runner
trims stdout and JSON-parses it; Hash/Array becomes `output_json`,
anything else falls through to `{}`. An explicit (parseable) file
always overrides stdout. Malformed JSON in an explicit file still
surfaces as `invalid_output`. So a one-liner producer block is just:

```
command `echo '{"score":85}'`
```

…and downstream blocks read `{{scorer.score}}` via templating, no
matter which runner picked the block up. The shell-internal `\"` you
sometimes see inside multi-statement blocks
(`sh -c "...; echo '{\"raw\":true}'"`) is not DSL escaping — it's the
shell's own syntax for putting `'...'` inside `"..."`, and it can't
be removed without breaking POSIX shell quoting rules.

### SQLite `:memory:` and WAL

`PRAGMA journal_mode = WAL` is skipped for `:memory:` databases (it's
not supported there). All file-backed DBs use WAL so concurrent reads
don't block writes. The condition lives in `lib/prouterd/storage/db.rb`.

### Subprocess LLM env: strict mode is opt-in

`Open3.popen3(env_hash, *argv)` merges `env_hash` on top of the
parent process's full env. So `LlmSubprocess` with a plain
`env = {"HOME" => "/x"}` still leaks every var the daemon was
started with into the subprocess. To get a tight env, pass
`unsetenv_others: true` in the spawn options hash; only the keys
in `env_hash` are then visible to the child.

The strict path is gated on the operator declaring at least one
of `env` / `env-forward` / `secret` on `interface llm`. Absent any
of these, the spawn keeps the inherit-all behaviour for
back-compat. If you add a new env-related directive to a
subprocess iface plugin, add it to the strict-mode trigger in
`LlmCaller#build_subprocess_env` (and the agentic-path mirror in
`AgenticRunner#build_subprocess_env`) — otherwise the operator
gets a half-sandboxed spawn.

Also: `unsetenv_others: true` drops `PATH`. If the agent shells
out (codex frequently does), the operator needs to
`env-forward PATH` explicitly. Document this on any new sandbox
opt-in field too.

### Streaming subprocess LLM: log_sink on RunRequest

`RunRequest#log_sink` is an optional `Proc<(content, stream)>` that
`BlockExecutor` builds per step (captures step.id, run.id,
db_mutex, redactor). Runners that want to emit log lines as they
arrive — currently only `LlmSubprocess` with `stream on` — invoke
the sink per JSONL line. The sink wraps `@runs.append_log` in
db_mutex AND publishes `:log_appended` on the events bus, so a
single call gives both persistence and live-tail via `/v1/events`.

The runner is responsible for not double-writing: when the sink is
used, set `result.stdout = ""` so `BlockExecutor#persist_logs`
doesn't bulk-write the same content again at end-of-step.
LlmSubprocess already returns `stdout: ""` for all paths, so this
is automatic; if you add another streaming runner, mirror that.

### Cron schedules: timezone in expression

Fugit doesn't take a separate timezone parameter. We append the
interface's `timezone` field to the schedule string:

```
"0 9 * * *" + " Europe/Berlin"  →  Fugit.parse_cron(...)
```

If you change how timezones are stored, update
`Scheduler#parse_cron` in [`lib/prouterd/runtime/scheduler.rb`](lib/prouterd/runtime/scheduler.rb).

## Testing

```bash
bundle exec rspec                          # full suite (~2800 specs, ~37s)
bundle exec rspec spec/prouterd/runtime/   # one subsystem
bundle exec rspec spec/prouterd/runtime/orchestrator_spec.rb:42  # one example
COVERAGE=1 bundle exec rspec               # writes coverage/index.html
```

`spec/spec_helper.rb` sets `PROUTERD_DB` to a per-run tmpdir so
shell/CLI tests never pollute the project root with a stray
`var/prouterd.db`. Tests that need a real DB use `Tempfile.create` or
`Storage::DB.open(":memory:")`.

The Docker-dependent paths use `Runner::StubRunner` from
`lib/prouterd/runner/stub_runner.rb`. Program per-block behavior or
queue FIFO results, then assert on `runner.calls` (captured RunRequests).

For end-to-end Docker tests, see `examples/` — those scripts run real
containers and assert on persisted state.

### Coverage gate (100% line + 100% branch)

CI runs with `COVERAGE=1` and fails on any drop below 100% line or
100% branch coverage (SimpleCov's `minimum_coverage` exits 2). When the
gate trips the `coverage/` directory is uploaded as a CI artifact, so
the offending lines/branches can be inspected without re-running locally.

`:nocov:` annotations are NOT permitted anywhere in `lib/`. The
historically-hard cases (signal handlers, infinite background loops,
optional `require` rescues, defensive guards) get one of two treatments:

1. **Refactor for testability** — extract the body into a named method
   the spec can drive directly, then verify the wrapper delegates.
   Examples: `daemon.rb`'s signal-trap bodies → `handle_term` /
   `handle_int`; `api/server.rb`'s drain loop → `drain_tick(now:)`.
2. **Delete the dead guard** — if a defensive `if X` can never be
   false given the caller's state machine, the guard is dead code, not
   a coverage hole. Delete it and let the active path stand alone.
   Examples: `next if rel.empty?` in collect_artifacts (Dir.glob never
   yields the root, and lstat.file? already drops directories).

If a single hard-case spec turns out genuinely impossible to write
under the no-`:nocov:` constraint, the resolution is to refactor the
lib code further (smaller seam, stub-friendly collaborator) — never to
add `:nocov:`.

## What's intentionally NOT here

These came up in design and were declined for v0.1. Don't add them
speculatively; wait for a real driver:

- **KubernetesCaller / S3 ArtifactStore.** Iface plugin system is
  pluggable; add a new plugin file with the caller class — no edits
  to parser/validator/renderer/show.
- **RBAC, mTLS, OIDC.** Webhook bearer auth + admin bearer for
  `/v1/*` are the only auth mechanisms today.
- **Idempotency keys.** At-least-once execution semantics are the
  documented contract; block authors are responsible for idempotency.
- **Cron catch-up after daemon outage.** `@last_fired` is in-memory.
  Misses during downtime are silently dropped.
- **Web UI inside this gem, distributed multi-daemon workers,
  advanced expression language.** A web console exists as a separate
  gem (`prouterd-web`) talking to the daemon over `/v1` HTTP + WS.
  The other two are out of scope.

For the full version-by-version history of what was built when, see
[CHANGELOG.md](CHANGELOG.md).
