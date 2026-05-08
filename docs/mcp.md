# MCP integration

prouterd speaks the [Model Context Protocol]. Declaring
`interface mcp <name>` makes the daemon spawn an MCP server
subprocess and exposes its tools to agentic blocks under the
namespace `<name>.<tool>`.

[Model Context Protocol]: https://modelcontextprotocol.io/

## Declaration

```prc
secret JIRA_TOKEN
 source env JIRA_TOKEN
exit

interface mcp atlassian
 server npx "@atlassian/mcp-server@1.4.2"
 cwd /opt/atp
 env JIRA_URL "https://example.atlassian.net"
 secret JIRA_TOKEN
 timeout-tool-call 30s
exit

interface llm codex
 provider anthropic
 model claude-sonnet-4-6
 auth bearer secret CLAUDE_KEY
exit

process triage
 block deep_dive
  interface llm codex
  prompt "Summarize SCT-{{event.issue.key}}"
  agentic on
  mcp atlassian
  allowed-tools atlassian.search_issues, atlassian.get_issue
  tool-call-limit 8
 exit
exit
```

`mcp <iface>` per-block opt-in is required — the daemon won't auto-include
every MCP server's tools in every agentic block. `allowed-tools` is an
optional further filter; without it, every tool advertised by the named
mcp interfaces is exposed.

## Server kinds

`server <kind> "<spec>"` — four kinds, in roughly increasing
production-readiness:

| Kind  | Resolves to                | When to use                                      |
|-------|----------------------------|--------------------------------------------------|
| `npx` | `npx -y <spec>`            | dev, single-host pilots — npm registry-fetched   |
| `uvx` | `uv tool run <spec>` (or `uvx <spec>`) | Python servers, teams already on uv |
| `bin` | `<spec>`                   | production, pinned binary in your image         |
| `raw` | shell-tokenised argv       | docker-isolated servers, exotic runners         |

Promote dev → prod by changing one line: `server npx "..."` →
`server bin "/usr/local/bin/..."`. Everything else stays put.

## Trust model

> **The MCP subprocess runs as the daemon user with the daemon's
> filesystem, network, and SQLite DB.**

A malicious MCP server can read your `prouterd.db` (which holds run
history, token-resolved env vars, and any secrets your `.prc`
declared). It can call any external service the daemon's network
egress allows.

prouterd does NOT add a sandbox layer. Isolation is your choice via
the invocation method:

- **For our own / audited servers** — `server bin "/usr/local/bin/..."`
  with a binary you compiled and shipped via your image bake.

- **For published / 3rd-party servers** — `server raw "docker run --rm
  -i ..."`. The container gives you network/filesystem isolation;
  pin the image tag.

  ```
  server raw "docker run --rm -i --network=mynet --read-only \
                          -e JIRA_URL my-org/atlassian-mcp:1.4.2"
  ```

  Note: `-i` is required (server speaks stdio), `--rm` for
  disposability, image tag pins version.

- **`server npx "..."` is convenient but unsafe by default.**
  Anyone publishing an npm package whose name you typed gets execution
  on your daemon's box, including via `postinstall` scripts. Use this
  for a few minutes during dev; switch to `bin` or
  `raw "docker run -i ..."` before exposing the daemon to real
  workloads.

## Secret threading

Secrets reach the subprocess via env vars only. No template
substitution into the server command line.

```prc
interface mcp atlassian
 server npx "@atlassian/mcp-server"
 secret JIRA_TOKEN              ! resolved at spawn → env JIRA_TOKEN=<value>
 secret SLACK_WEBHOOK            ! same; multiple are allowed
exit
```

`server raw "docker run -e TOKEN={{secret.X}} ..."` is **rejected by
the validator** — it would be a shell-injection vector. Pass through
env: `server raw "docker run -e TOKEN -i ..."`, then `secret TOKEN`.

## Replay reproducibility

prouterd's runs are bound to a config commit at trigger time. MCP
tools live in the subprocess, not in the commit, so they could change
between trigger and replay (server upgraded, tool renamed).

Mitigation: at trigger time, prouterd snapshots `tools/list` per mcp
interface into `runs.mcp_tools_json`. On replay, the orchestrator
fails clean (`error_type: "unknown_tool"`) if a previously-used tool
is no longer advertised. To fully reproduce a run after an MCP server
upgrade, pin the server (`server bin "/path/to/old/binary"` or
`server raw "docker run ... :1.4.2"`).

## Lifecycle

- **Daemon start** — `Daemon::Main` builds the pool from the running
  config. Each `interface mcp <name>` gets one Session: spawn → handshake
  → tools/list. Failures (subprocess can't spawn, handshake times out)
  mark the interface `:degraded`; the operator sees them in
  `show logging facility MCP` and per-iface health.
- **Tool dispatch** — agentic blocks reach the pool via
  `Pool#call_tool("<iface>.<tool>", input, timeout_ms:)`. Concurrent
  blocks share one Session per iface; JSON-RPC ids correlate
  responses to the right caller.
- **Daemon stop** — graceful drain: `shutdown` notification → close
  pipes → SIGTERM (5s grace) → SIGKILL. Subprocess always reaps.
- **Config apply** — Pool reconciliation: removed mcp interfaces
  stop, new ones spawn. (Hot-reload of changed-spec interfaces is
  conservative: stop + respawn on every reconcile in v0; will be
  refined in a future phase.)

## Operations

`show logging facility MCP` tails the structured log lines:

| Mnemonic         | Severity | When                                       |
|------------------|----------|--------------------------------------------|
| `MCP-6-READY`    | info     | Session up, tools/list returned            |
| `MCP-3-START_FAILED` | error | Spawn / handshake failed                  |
| `MCP-4-RECONCILE_ERR` | warn | Reconcile during apply raised             |
| `MCP-3-UNRESOLVABLE` | error | server-spec couldn't be resolved to argv |
| `MCP-6-REMOVED`  | info     | Interface dropped on reconcile             |
| `MCP-4-BAD_FRAME` | warn    | Server emitted non-JSON on stdout         |
| `MCP-7-NOTIFY`   | debug    | Server pushed an unsolicited notification |
| `MCP-7-STDERR`   | debug    | Server stderr line (last 100 cached)       |

## Out of scope (v0)

- `resources/*` and `prompts/*` — only `tools/*` is supported.
- `sampling/createMessage` — server-initiated LLM calls; rare,
  responded-to with `method not supported`.
- SSE / WebSocket transports — stdio only.
- prouterd-as-MCP-server (exposing prouterd's own tools to Claude
  Desktop, Cursor, etc) — separate feature, distinct proposal.

## Reference

- [Model Context Protocol spec](https://spec.modelcontextprotocol.io/)
- [Servers index](https://github.com/modelcontextprotocol/servers)
- `lib/prouterd/iface/mcp/session.rb` — JSON-RPC 2.0 client
- `lib/prouterd/iface/mcp/pool.rb` — process-singleton session holder
- `examples/14_mcp_filesystem.prc` — minimal walkthrough
