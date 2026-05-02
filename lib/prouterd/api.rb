require_relative "api/auth"
require_relative "api/metrics"
require_relative "api/rate_limiter"
require_relative "api/webhook_handler"
require_relative "api/v1"
require_relative "api/app"

module Prouterd
  module API
    # Server is loaded lazily so requiring `prouterd` doesn't pull in puma at
    # boot — only `prouter serve` instantiates it.
    autoload :Server, File.expand_path("api/server", __dir__)
  end
end
