$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "prouterd"

FIXTURES_DIR = File.expand_path("fixtures", __dir__)

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
