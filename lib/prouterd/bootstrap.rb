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

    # Build the per-execution-type runner map. `real`/`docker` asks each
    # registered Plugin for its runner. `shell` routes every type to
    # ShellRunner (docker-less hosts). `stub` is the test fixture.
    def build_runner(kind, in_flight: nil)
      opts = { in_flight: in_flight }
      case kind
      when nil, "real", "docker"
        Prouterd::Runner::Registry.all.each_with_object({}) do |plugin, h|
          h[plugin.type_name] = plugin.build_runner(opts)
        end
      when "shell"
        shell = Prouterd::Runner::ShellRunner.new
        Prouterd::Runner::Registry.types.each_with_object({}) do |type, h|
          h[type] = shell
        end
      when "stub"
        stub = Prouterd::Runner::StubRunner.new
        Prouterd::Runner::Registry.types.each_with_object({}) do |type, h|
          h[type] = stub
        end
      else
        allowed = (%w[real shell stub] + Prouterd::Runner::Registry.types).uniq.join("|")
        @stderr.puts "prouter: unknown runner kind '#{kind}' (#{allowed})"
        :error
      end
    rescue LoadError, StandardError => e
      @stderr.puts "prouter: cannot initialize runner '#{kind}': #{e.message}"
      :error
    end
  end
end
