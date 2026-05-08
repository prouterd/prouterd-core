#!/usr/bin/env ruby
# Minimal MCP server fake. Speaks JSON-RPC 2.0 over stdio, responds
# to `initialize`, `tools/list`, `tools/call`, `shutdown`.
# Configurable via env:
#   MCP_FAKE_TOOLS  — JSON array of tool descriptors (default: 1 echo tool)
#   MCP_FAKE_DELAY  — seconds to sleep before answering tools/call
#   MCP_FAKE_FAIL   — if "1", tools/call returns a JSON-RPC error frame
require "json"

$stdout.sync = true

tools = if ENV["MCP_FAKE_TOOLS"]
          JSON.parse(ENV["MCP_FAKE_TOOLS"])
        else
          [{
            "name"        => "echo",
            "description" => "echo the input",
            "inputSchema" => {
              "type"       => "object",
              "properties" => { "msg" => { "type" => "string" } },
              "required"   => ["msg"]
            }
          }]
        end

fail_calls = ENV["MCP_FAKE_FAIL"] == "1"
delay      = ENV["MCP_FAKE_DELAY"]&.to_f

while (line = $stdin.gets)
  line.strip!
  next if line.empty?

  frame =
    begin
      JSON.parse(line)
    rescue JSON::ParserError
      next
    end

  id     = frame["id"]
  method = frame["method"]
  params = frame["params"] || {}

  case method
  when "initialize"
    $stdout.puts JSON.dump(
      "jsonrpc" => "2.0", "id" => id,
      "result"  => {
        "protocolVersion" => "2024-11-05",
        "capabilities"    => { "tools" => {} },
        "serverInfo"      => { "name" => "fake", "version" => "0.0.0" }
      }
    )
  when "notifications/initialized", "shutdown"
    # notifications: no response
    next
  when "tools/list"
    $stdout.puts JSON.dump(
      "jsonrpc" => "2.0", "id" => id,
      "result"  => { "tools" => tools }
    )
  when "tools/call"
    sleep(delay) if delay && delay > 0
    if fail_calls
      $stdout.puts JSON.dump(
        "jsonrpc" => "2.0", "id" => id,
        "error"   => { "code" => -32000, "message" => "fake server fail" }
      )
    else
      tool_name = params["name"]
      args      = params["arguments"] || {}
      $stdout.puts JSON.dump(
        "jsonrpc" => "2.0", "id" => id,
        "result"  => {
          "content" => [
            { "type" => "text",
              "text" => JSON.dump(tool: tool_name, args: args, env_jira: ENV["JIRA_TOKEN"]) }
          ],
          "isError" => false
        }
      )
    end
  else
    $stdout.puts JSON.dump(
      "jsonrpc" => "2.0", "id" => id,
      "error"   => { "code" => -32601, "message" => "method not found" }
    )
  end
end
