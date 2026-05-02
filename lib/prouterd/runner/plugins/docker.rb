require_relative "../plugin"
require_relative "../registry"

module Prouterd
  module Runner
    module Plugins
      # Built-in `type docker` block: runs the block as a Docker container.
      # Field schema feeds parser/validator/renderer/show automatically —
      # no other file needs to know that "docker" exists.
      class Docker < Plugin
        type "docker"

        field :image,   kind: :string,  required: true, description: "container image reference"
        field :command, kind: :command, description: "argv override (image's CMD)"
        field :pull,    kind: :enum, enum: %w[never if-missing always],
                        description: "image pull policy"
        field :network, kind: :enum, enum: %w[on off], default: "on",
                        description: "network access on/off"
        field :user,    kind: :string, description: "uid, name, or uid:gid"
        field :memory,  kind: :string, description: "memory limit (512m, 1g, ...)"
        field :cpu,     kind: :string, description: "CPU limit (decimal CPUs, e.g. 0.5)"

        runner "Prouterd::Runner::DockerRunner"
      end

      Registry.register!(Docker)
    end
  end
end
