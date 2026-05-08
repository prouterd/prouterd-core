! Minimal MCP integration example.
!
! Spins up the official @modelcontextprotocol/server-filesystem MCP
! server, exposes its read_file / list_directory / search_files tools
! to an agentic block, and lets the model answer questions about a
! directory.
!
! Trust note: this server runs as the daemon user with read access
! to whatever path you pass in `server`. For an audited tree (your
! own repo) this is fine; for arbitrary directories prefer
!
!   server raw "docker run --rm -i -v /allowed:/allowed \
!                          modelcontextprotocol/server-filesystem /allowed"
!
! See docs/mcp.md for the full trust model.

router demo
exit

secret CLAUDE_KEY
 source env CLAUDE_API_KEY
exit

interface llm codex
 provider anthropic
 model claude-sonnet-4-6
 auth bearer secret CLAUDE_KEY
exit

interface mcp fs
 server npx "@modelcontextprotocol/server-filesystem /tmp/notes"
 timeout-tool-call 15s
exit

interface manual cli
 no shutdown
exit

process ask
 block answer
  interface llm codex
  prompt "{{event.question}}\n\nReply only with what the tools tell you. No guessing."
  agentic on
  mcp fs
  ! Without `allowed-tools`, every tool the server advertises is exposed.
  ! Add `allowed-tools fs.read_file, fs.list_directory` to scope tighter.
  tool-call-limit 8
 exit
exit

route interface cli process ask
exit

! Trigger:
!   prouter trigger ask --event '{"question":"What files mention TODO?"}'
