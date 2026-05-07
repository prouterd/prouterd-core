require "rack"

module Prouterd
  module API
    # Bearer-token authentication for /v1/* endpoints, the WS handshake
    # on /v1/events and /v1/cli/:sid, and webhook interfaces.
    #
    # Tokens are accepted in either of two equivalent forms:
    #
    #   - `Authorization: Bearer <token>` HTTP header — the standard
    #     path used by curl / SDK clients / non-browser code.
    #   - `?token=<token>` query parameter — fallback for cases where
    #     the client can't set custom headers: WebSocket handshakes
    #     from a browser, plain `<a download>` artifact links, etc.
    #
    # Comparison uses Rack::Utils.secure_compare so a timing-channel
    # attacker can't recover the token byte-by-byte.
    module Auth
      module_function

      # Returns the bearer token presented by the request, or nil if
      # neither the Authorization header nor the ?token= query
      # parameter is set. Accepts a Rack env hash or a Rack::Request.
      def token_from(env_or_request)
        env = env_or_request.respond_to?(:env) ? env_or_request.env : env_or_request

        header = env["HTTP_AUTHORIZATION"].to_s
        if header.start_with?("Bearer ")
          provided = header.sub(/\ABearer\s+/, "").strip
          return provided unless provided.empty?
        end

        query = env["QUERY_STRING"].to_s
        return nil if query.empty?

        parsed = Rack::Utils.parse_nested_query(query)
        token  = parsed["token"]
        return nil unless token.is_a?(String) && !token.empty?

        token
      end

      # Returns nil on success, or a [status, message] tuple to refuse with.
      # Reads the token via `token_from` so header and query are equivalent.
      def check_bearer(request, expected_token)
        provided = token_from(request)
        return [401, "missing bearer token"] if provided.nil? || provided.empty?
        return [503, "auth secret not configured"] if expected_token.nil? || expected_token.empty?

        ok = Rack::Utils.secure_compare(provided, expected_token)
        ok ? nil : [403, "bearer token rejected"]
      end
    end
  end
end
