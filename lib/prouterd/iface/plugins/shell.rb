# frozen_string_literal: true

require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface shell <name>` — declares a host-process execution
      # environment (working directory, shell binary, baseline env vars).
      # Blocks that reference it supply the per-call `exec` line.
      #
      # Replaces the legacy block-side `type shell { ... }` subsection.
      # Block runs under the daemon's user with the daemon's filesystem
      # (modulo `cwd`) — use only for trusted local code.
      #
      # Example:
      #
      #   interface shell ruby_blocks
      #    cwd ./blocks
      #    shell /bin/bash
      #   exit
      #
      #   block format_pr
      #    interface shell ruby_blocks
      #    exec "ruby format_pr.rb"
      #   exit
      class Shell < Plugin
        type "shell"
        direction :outbound

        # Interface-level: execution environment, shared across blocks.
        field :cwd,   kind: :string,
                      description: "working directory; relative to daemon CWD"
        field :shell, kind: :string,
                      description: "path to the shell interpreter (default /bin/sh)"
        field :env,   kind: :env_pair,
                      description: "baseline env vars: env KEY VALUE; repeats accumulate"

        # Per-call: the actual command line to run.
        call_field :exec, kind: :command, required: true,
                          description: "argv to execute; templated"

        caller "Prouterd::Runner::ShellRunner"
      end

      Registry.register!(Shell)
    end
  end
end
