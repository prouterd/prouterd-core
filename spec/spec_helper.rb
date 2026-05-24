# Opt-in coverage. `COVERAGE=1 bundle exec rspec` produces a report at
# coverage/index.html; plain `bundle exec rspec` skips the overhead.
# SimpleCov must boot BEFORE prouterd is required so it can hook every
# line load.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/vendor/"
    add_filter "/examples/"
    enable_coverage :branch

    add_group "Config",   "lib/prouterd/config"
    add_group "Runtime",  "lib/prouterd/runtime"
    add_group "Runner",   "lib/prouterd/runner"
    add_group "Iface",    "lib/prouterd/iface"
    add_group "API",      "lib/prouterd/api"
    add_group "Shell",    "lib/prouterd/shell"
    add_group "Storage",  "lib/prouterd/storage"
    add_group "CLI",      "lib/prouterd/cli"
    add_group "Util",     "lib/prouterd/util"
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "prouterd"
require "tmpdir"

# Spec support files (helpers, shared contexts).
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

FIXTURES_DIR = File.expand_path("fixtures", __dir__)

# Per-test-run scratch dir. PROUTERD_DB defaults here so a stray `prouter shell`
# in tests never lands a SQLite file in the project root.
SPEC_TMPDIR = Dir.mktmpdir("prouterd-spec-")
ENV["PROUTERD_DB"] = File.join(SPEC_TMPDIR, "test.sqlite3")
at_exit { FileUtils.remove_entry(SPEC_TMPDIR) if File.directory?(SPEC_TMPDIR) }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = false

  config.default_formatter = "doc" if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed
end

def fixture_path(name)
  File.join(FIXTURES_DIR, name)
end

def read_fixture(name)
  File.read(fixture_path(name))
end

# Helper for tests that need a fresh isolated SQLite DB.
def with_temp_db
  Tempfile.create(["prouterd-test-db", ".sqlite3"]) do |tmp|
    tmp.close
    db = Prouterd::Storage::DB.open(tmp.path)
    begin
      yield db
    ensure
      db.close
    end
  end
end
