require_relative "lib/prouterd/version"

Gem::Specification.new do |spec|
  spec.name        = "prouterd"
  spec.version     = Prouterd::VERSION
  spec.authors     = ["Nikolay Falshunov"]
  spec.summary     = "Process Router: a CLI-first process orchestrator with router-style config"
  spec.description = "Events route through declarative rules to isolated executable blocks. " \
                     "Configured via line-oriented .prc DSL, operated via interactive shell."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.glob("{lib,exe}/**/*") + %w[prouterd.gemspec README.md].select { |f| File.exist?(f) }
  spec.bindir      = "exe"
  spec.executables = ["prouter"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sqlite3", "~> 2.1"
  spec.add_dependency "docker-api", "~> 2.4"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.2"
end
