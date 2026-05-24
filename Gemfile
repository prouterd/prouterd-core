source "https://rubygems.org"

gemspec

# Optional caller dependencies for bundled deployments. They remain out of
# prouterd.gemspec runtime deps so `gem install prouterd` stays lean; the
# Docker image installs this Gemfile with development excluded and still gets
# docker/postgres/cron support.
gem "docker-api", "~> 2.4"
gem "pg",         "~> 1.5"
gem "fugit",      "~> 1.11"
