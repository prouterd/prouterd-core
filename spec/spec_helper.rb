$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "prouterd"
require "tmpdir"

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
