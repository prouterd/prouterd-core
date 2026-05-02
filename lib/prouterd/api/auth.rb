require "rack"

module Prouterd
  module API
    # Bearer-token authentication for webhook interfaces.
    #
    # Spec §10.5/§23: secret values arrive resolved (typically via
    # EnvSecretResolver). Comparison uses Rack::Utils.secure_compare so a
    # timing-channel attacker can't recover the token byte-by-byte.
    module Auth
      module_function

      # Returns nil on success, or a [status, message] tuple to refuse with.
      def check_bearer(request, expected_token)
        header = request.get_header("HTTP_AUTHORIZATION").to_s
        unless header.start_with?("Bearer ")
          return [401, "missing bearer token"]
        end

        provided = header.sub(/\ABearer\s+/, "").strip
        return [401, "missing bearer token"] if provided.empty?
        return [503, "auth secret not configured"] if expected_token.nil? || expected_token.empty?

        ok = Rack::Utils.secure_compare(provided, expected_token)
        ok ? nil : [403, "bearer token rejected"]
      end
    end
  end
end
