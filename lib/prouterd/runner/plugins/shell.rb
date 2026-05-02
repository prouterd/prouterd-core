require_relative "../plugin"
require_relative "../registry"
require_relative "../shell_runner"

module Prouterd
  module Runner
    module Plugins
      # Built-in `type shell` block: runs the block as a host process via
      # Open3. The /prouter/{input.json,output.json,artifacts} contract is
      # honored on the host filesystem instead of inside a container.
      class Shell < Plugin
        type "shell"

        field :exec,  kind: :command, required: true, description: "shell command line"
        field :cwd,   kind: :string,  description: "working directory"
        field :shell, kind: :string,  description: "shell binary (default /bin/sh)"
        field :env,   kind: :env_pair, description: "extra environment variable"

        runner Prouterd::Runner::ShellRunner
      end

      Registry.register!(Shell)
    end
  end
end
