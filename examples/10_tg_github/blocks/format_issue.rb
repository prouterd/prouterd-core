#!/usr/bin/env ruby
# See format_pr.rb for the input/output contract — same idea for issues.

require "json"

data  = JSON.parse(File.read(ENV.fetch("PROUTER_INPUT_PATH")))
event = data.fetch("input")

issue  = event.fetch("issue")
repo   = event.dig("repository", "full_name")
author = issue.dig("user", "login")
title  = issue.fetch("title")
url    = issue.fetch("html_url")

text = "🐛 *#{repo}* — new issue\n*#{title}* by `#{author}`\n#{url}"

File.write(ENV.fetch("PROUTER_OUTPUT_PATH"), JSON.dump("text" => text))
