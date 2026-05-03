#!/usr/bin/env ruby
# Reads /prouter/input.json (provided by the runner via PROUTER_INPUT_PATH),
# pulls the GitHub PR event from the `input` slice, and writes a small
# {"text": "..."} JSON to /prouter/output.json that the next block hands
# off verbatim to Telegram's sendMessage API.

require "json"

data  = JSON.parse(File.read(ENV.fetch("PROUTER_INPUT_PATH")))
event = data.fetch("input")

pr     = event.fetch("pull_request")
action = event.fetch("action")
repo   = event.dig("repository", "full_name")
author = pr.dig("user", "login")
title  = pr.fetch("title")
url    = pr.fetch("html_url")

emoji =
  case action
  when "opened"           then "🟢"
  when "ready_for_review" then "👀"
  when "closed"           then pr["merged"] ? "🟣 merged" : "🔴 closed"
  else                         "📬"
  end

text = "#{emoji} *#{repo}* — PR #{action}\n*#{title}* by `#{author}`\n#{url}"

File.write(ENV.fetch("PROUTER_OUTPUT_PATH"), JSON.dump("text" => text))
