# frozen_string_literal: true

require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Iface
    module Plugins
      # `interface docker <name>` — declares a Docker image (and resource
      # limits) that one or more blocks invoke. Each block supplies its own
      # `command` per call. Replaces the legacy block-side `type docker { ... }`
      # subsection.
      #
      # Example — three blocks share the same Python environment:
      #
      #   interface docker python
      #    image my-team/py3.11:v2
      #    memory 1g
      #   exit
      #
      #   block train_model
      #    interface docker python
      #    command "python train.py"
      #   exit
      #
      #   block eval_model
      #    interface docker python
      #    command "python evaluate.py"
      #   exit
      class Docker < Plugin
        type "docker"
        direction :outbound

        # Interface-level: container environment, shared across blocks.
        field :image,   kind: :string, required: true,
                        description: "container image reference"
        field :pull,    kind: :enum, enum: %w[never if-missing always],
                        description: "image pull policy"
        field :network, kind: :enum, enum: %w[on off], default: "on",
                        description: "network access on/off"
        field :user,    kind: :string,
                        description: "uid, name, or uid:gid"
        field :memory,  kind: :string,
                        description: "memory limit (512m, 1g, ...)"
        field :cpu,     kind: :string,
                        description: "CPU limit (decimal CPUs, e.g. 0.5)"

        # Per-call: argv override of the image's CMD. Optional — if the image
        # has its own ENTRYPOINT/CMD that's a runnable default, the block can
        # omit `command` and simply invoke the image.
        call_field :command, kind: :command,
                             description: "argv override (image's CMD); templated"

        caller "Prouterd::Runner::DockerRunner"
      end

      Registry.register!(Docker)
    end
  end
end
