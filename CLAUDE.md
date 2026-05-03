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

For block fields, decide whether the field is **type-specific** (only
applies to one runner type) or **common**:

- **Type-specific** (image/command/pull/... for docker; exec/cwd/... for
  shell): declared on the runner's plugin class via `field :foo, kind: :...`.
  See "Adding a new runner type" below — adding a type-specific field is
  one line in one plugin file, no edits to parser/renderer/validator.
- **Common** (input, output, produces, timeout, retry, contract, secret,
  enable/disable): handled in `parse_block_field` and rendered between the
  type sub-section and the closing `exit` of the block. The 5-step
  recipe above applies for these.

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
- **Runner dispatch is plugin-driven.** The set of legal `type <name>`
  keywords inside a block is whatever's currently registered in
  `Runner::Registry`. Parser, validator, renderer, `show`, tracer, and
  CLI all iterate over the registry and the plugin's declared field
  schema — they hardcode no type names. See "Adding a new runner type"
  below.
- **Logging is structured.** Build one `Prouterd::Logger` in `cmd_serve`
  and thread it through all components via `logger:` kwarg. Format is
  `<ts> <LEVEL> prouterd: <message> k=v k=v…` — single-line, grep-able,
  no JSON unless a value contains spaces/`=`. Do NOT use `puts` /
  `@output.puts` in `lib/`. Tests pass `Prouterd::NullLogger.new`.
- **Operational knobs go through ENV.** New behavior that an operator
  might want to tune (cap, timeout, path) reads
  `PROUTERD_<UPPER_SNAKE>` with a sensible compile-time default. Never
  put operational tunables in `.prc` files — those are for *intent*,
  ENV is for *deployment*. Document the new var in README's "Production
  env vars" table.

## Adding a new runner type

A runner type is one plugin file + one Runner class. **Nothing else in the
codebase needs to change** — parser/validator/renderer/show/tracer/CLI all
discover the new type through `Runner::Registry`.

### 1. Write the runner

Implement `#run(RunRequest) -> ExecutionResult`. Read your inputs from
`request.field("foo")` (a thin wrapper over `request.type_fields["foo"]`).
The `/prouter/{input.json,output.json,artifacts/,inputs/}` contract is
the invariant — your runner decides where those paths physically live
(host fs for shell, container mount for docker, CRD for k8s, etc.);
block authors write the same code regardless.

If `request.staged_inputs` is non-empty, copy each `<src_path>` to
`/prouter/inputs/<local_name>` so the orchestrator's
`PROUTER_INPUT_<NAME>` env vars resolve. See `DockerRunner#stage_inputs`
and `ShellRunner#stage_inputs` for reference.

```ruby
# lib/prouterd/runner/lambda_runner.rb
module Prouterd::Runner
  class LambdaRunner
    def initialize(in_flight: nil); @in_flight = in_flight; end

    def run(request)
      arn = request.field("arn")
      payload = request.input_json
      # ... invoke AWS Lambda, capture result, build ExecutionResult ...
    end
  end
end
```

### 2. Write the plugin

Subclass `Runner::Plugin`, declare the `type` keyword, list the fields,
point at the runner class. One file, no boilerplate elsewhere.

```ruby
# lib/prouterd/runner/plugins/lambda.rb
require_relative "../plugin"
require_relative "../registry"

module Prouterd::Runner::Plugins
  class Lambda < Prouterd::Runner::Plugin
    type "lambda"

    field :arn,    kind: :string, required: true, description: "Lambda function ARN"
    field :region, kind: :string, default: "us-east-1"
    field :sync,   kind: :enum, enum: %w[on off], default: "on"

    runner "Prouterd::Runner::LambdaRunner"
  end

  Prouterd::Runner::Registry.register!(Lambda)
end
```

Field kinds:

- `:string` — single token (word or quoted string)
- `:enum` — must match `enum:` list
- `:command` — joins all remaining tokens, always quoted in canonical render
- `:env_pair` — `KEY value` accumulating into a Hash<String,String>

Pass `runner` as a class OR a String class name. Strings are resolved
lazily — useful when the runner pulls in a heavy dependency (e.g.
`docker-api`) that you only want loaded when the runner is actually used.

### 3. Make Prouterd load it

Built-in plugins are required from `lib/prouterd/runner.rb`. Third-party
plugins (in a separate gem) just `require` their plugin file at boot;
the `Registry.register!` call at the bottom of the file does the rest.

That's it. `prouter check`, `prouter render`, `prouter shell`, `prouter
trigger`, and the daemon all immediately understand `type lambda`. The
test in `spec/prouterd/runner/plugin_spec.rb` exercises the full chain on
a fake `printer` plugin and is the worked reference.

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

Block command strings in `.prc` go through:

1. Lexer (`\"` → `"`, `\\` → `\`)
2. Stored verbatim in `block.command`
3. **Renderer must quote them** — otherwise apply→reload loses spaces
   and quotes. Currently fixed: `quote_string(block.command)` in
   [`renderer.rb`](lib/prouterd/config/renderer.rb).
4. Runner uses `Shellwords.split` to break into argv for Docker.
5. Inside the container, `sh -c` re-parses.

Net effect: to write `{"score":85}` to output.json from a shell-quoted
command, you need TWO levels of escaping in the DSL string:

```
command "sh -c 'echo \"{\\\"score\\\":85}\" > /prouter/output.json'"
```

The `examples/` show this pattern. For real pipelines, just use a custom
container image where the JSON construction is in code, not shell.

### SQLite `:memory:` and WAL

`PRAGMA journal_mode = WAL` is skipped for `:memory:` databases (it's
not supported there). All file-backed DBs use WAL so concurrent reads
don't block writes. The condition lives in `lib/prouterd/storage/db.rb`.

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
bundle exec rspec                  # full suite (~460 specs)
bundle exec rspec spec/prouterd/runtime/   # one subsystem
bundle exec rspec spec/prouterd/runtime/orchestrator_spec.rb:42  # one example
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

## What's intentionally NOT here

These came up in design and were declined for v0.1. Don't add them on
spec; wait for a real driver:

- **Postgres adapter.** `Storage::DB` is a thin wrapper, but only the
  SQLite implementation exists. SQL itself is portable; transaction
  semantics, `last_insert_row_id`, and `RETURNING` would need adapting.
- **KubernetesRunner / S3 ArtifactStore.** Runner interface is
  pluggable (Phase 12); add a new entry in `AST::Block::EXECUTION_TYPES`,
  parse/validate/render its `type` sub-section, and add the runner class.
  Nobody has asked yet.
- **RBAC, mTLS, OIDC.** Spec §23.4 future-version. Webhook bearer auth
  + admin bearer for `/v1/*` are the only auth mechanisms today.
- **Idempotency keys** (spec §12.6 future). At-least-once execution
  semantics are the documented contract; block authors are responsible
  for idempotency.
- **Cron catch-up after daemon outage.** `@last_fired` is in-memory.
  Misses during downtime are silently dropped — by spec §31, "not MVP".
- **Web UI, distributed multi-daemon workers, advanced expression
  language.** Spec §3 ("non-goals") and §31 explicitly out of scope.

## What the spec says vs what's built

Spec §28 lists the acceptance criteria. All five categories pass.
Spec §29 lists 8 phases — all 8 are committed in git history (one
commit per phase). Spec §31 lists the "narrowest MVP" — every item
on that list is implemented.

The codebase has gone beyond the original spec in three ways:

- **Phases 9-11**: cancel + diff + cron, then full /v1 HTTP API +
  /metrics + graceful shutdown + cleanup, then SQLite-backed job queue
  with crash-survivable in-flight runs.
- **Phase 12 (separate Block Execution Types spec)**: removes Docker
  centrism. Each block declares `type docker` or `type shell` in a
  sub-section; `ShellRunner` runs blocks as host processes via Open3.
  Same `/prouter/*` contract for both. Mixed pipelines work.

The spec also lists "non-goals" (non-goals) — visual editor, full Temporal
replacement, low-code canvas, distributed workers. Those are still
non-goals.
