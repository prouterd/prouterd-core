source "https://rubygems.org"

gemspec

# Optional caller dependencies for bundled deployments. They remain out of
# prouterd.gemspec runtime deps so `gem install prouterd` stays lean; the
# Docker image installs this Gemfile with development excluded and still gets
# docker/postgres/cron support.
gem "docker-api", "~> 2.4"
gem "pg",         "~> 1.5"
gem "fugit",      "~> 1.11"

# Test coverage tooling. Opt-in: spec_helper only requires simplecov when
# COVERAGE=1 is set, so day-to-day `bundle exec rspec` stays fast.
group :development, :test do
  gem "simplecov", "~> 0.22", require: false
end
