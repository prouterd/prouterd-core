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
because they delegate to the parser's `apply_X_field` methods. If your
field is on `Process` / `Block` / `ProcessRoute` / `GlobalRoute` you
might also want a typed handler in the corresponding mode for
auto-completion or special UX, but the default fall-through works.

## Adding a new shell command

1. Add the dispatch entry in the relevant mode's `commands` hash
   (`lib/prouterd/shell/modes/*.rb`).
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
bundle exec rspec                  # full suite (~280 specs)
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

- **Worker pool with DB polling.** Current async path is `Thread.new`
  from the webhook/scheduler. Daemon crash loses in-flight runs (the
  recovery sweep on next boot marks them failed). A `WHERE status='queued'
  AND locked_at IS NULL` polling pool would survive crashes.
- **Hard cancel.** `cancel run` is soft: orchestrator polls run.status
  between levels and stops scheduling. In-flight containers finish
  naturally. Hard cancel needs a `run_uid → container_id` registry.
- **Postgres adapter.** `Storage::DB` is a thin wrapper, but only the
  SQLite implementation exists. SQL itself is portable; transaction
  semantics and `last_insert_row_id` would need adapting.
- **KubernetesRunner / S3 ArtifactStore.** Interfaces are clean; nobody
  has asked for them yet.
- **RBAC, mTLS, OIDC.** Spec §23.4 future-version. Webhook bearer auth
  is the only auth mechanism today.
- **Output schema validation.** Block contract mentions JSON, no schema
  enforcement. Add a `Block#output_schema` field and a validator pass
  in `execute_single_attempt` if needed.
- **Cron catch-up after daemon outage.** `@last_fired` is in-memory.
  Misses during downtime are silently dropped — by spec §31, "not MVP".

## What spec.md says vs what's built

Spec §28 lists the acceptance criteria. All five categories pass.
Spec §29 lists 8 phases — all 8 are committed in git history (one
commit per phase). Spec §31 lists the "narrowest MVP" — every item
on that list is implemented.

The spec also lists "non-goals" (non-goals) — visual editor, full Temporal
replacement, low-code canvas, distributed workers. Those are still
non-goals.
