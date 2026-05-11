# frozen_string_literal: true

require_relative "../prouterd"

module Prouterd
  # Shared bootstrapping helpers for entry-point binaries (CLI + daemon).
  #
  # The CLI client (`exe/prouter`) and the daemon (`exe/prouterd`) both
  # need to parse the same `--db` / `--runner` flags, open a SQLite-backed
  # ConfigStore, and build the per-type runner map. Putting that in one
  # place keeps the two binaries in lockstep.
  #
  # Mixin contract: hosting class provides `@stderr` (an IO).
  module Bootstrap
    def default_runner_kind
      ENV["PROUTERD_RUNNER"] || "docker"
    end

    # Opens a ConfigStore at the resolved path, or returns nil if `no_db` was
    # given. Returns `:error` (and prints to @stderr) on open failure.
    def open_store(explicit_path, no_db)
      return nil if no_db

      path = explicit_path || ENV["PROUTERD_DB"] || Prouterd::Storage::DB::DEFAULT_PATH
      db = Prouterd::Storage::DB.open(path)
      Prouterd::ControlPlane::ConfigStore.new(db)
    rescue SQLite3::Exception, Prouterd::Storage::StorageError => e
      @stderr.puts "prouter: cannot open DB at #{path}: #{e.message}"
      :error
    end

    # Build the orchestrator's runner. Always a `CallRunner`: it dispatches
    # by interface type at runtime, so one runner suffices.
    #
    # `kind` selects the dispatch policy:
    #   * "real" / "docker" / nil — normal CallRunner. Each block resolves
    #     to its declared `interface <type> <name>` and invokes the
    #     corresponding caller class (DockerRunner, ShellRunner, HttpCaller, ...).
    #   * "stub" — every block is handed to StubRunner. Tests use this.
    def build_runner(kind, in_flight: nil)
      case kind
      when nil, "real", "docker", "shell"
        Prouterd::Runner::CallRunner.new(in_flight: in_flight)
      when "stub"
        Prouterd::Runner::StubRunner.new
      else
        @stderr.puts "prouter: unknown runner kind '#{kind}' (real | shell | stub)"
        :error
      end
    rescue LoadError, StandardError => e
      @stderr.puts "prouter: cannot initialize runner '#{kind}': #{e.message}"
      :error
    end
  end
end
