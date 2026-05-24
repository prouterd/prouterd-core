require_relative "lib/prouterd/version"

Gem::Specification.new do |spec|
  spec.name        = "prouterd"
  spec.version     = Prouterd::VERSION
  spec.authors     = ["Nikolay Falshunov"]
  spec.summary     = "Process Router: a CLI-first process orchestrator with router-style config"
  spec.description = "Events route through declarative rules to isolated executable blocks. " \
                     "Configured via line-oriented .prc DSL, operated via interactive shell."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir.glob("{lib,exe}/**/*") + %w[prouterd.gemspec README.md].select { |f| File.exist?(f) }
  spec.bindir      = "exe"
  spec.executables = ["prouter", "prouterd"]
  spec.require_paths = ["lib"]

  # Hard runtime dependencies — needed by the CLI (parse, validate,
  # render, apply, exec, shell) and the daemon's HTTP / WebSocket layer.
  # Everything else is opt-in.
  spec.add_dependency "sqlite3",         "~> 2.1"
  spec.add_dependency "puma",            "~> 8.0"
  spec.add_dependency "rack",            "~> 3.1"
  spec.add_dependency "faye-websocket",  "~> 0.11"

  # Optional runtime dependencies — lazy-required at first use. Installs
  # that never touch the corresponding feature don't pay the dep cost.
  # When the feature is exercised without the gem present, the caller
  # returns a clean error_type:"missing_dependency" result (Scheduler
  # logs once and disables cron firing).
  #
  #   gem install docker-api   # interface docker     (DockerRunner)
  #   gem install pg           # interface postgres   (PostgresCaller)
  #   gem install fugit        # interface cron       (Scheduler)
  #
  # interface http / llm / shell / webhook / manual all use only Ruby
  # stdlib (Net::HTTP, Open3, Rack) — no extra install needed.
  spec.add_development_dependency "rspec",      "~> 3.13"
  spec.add_development_dependency "rake",       "~> 13.2"
  spec.add_development_dependency "rack-test",  "~> 2.1"
end
