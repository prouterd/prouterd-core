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

      # ----- cookie-session auth (POST /v1/login + HttpOnly cookie) -----
      #
      # When the daemon hands the browser a cookie session via /v1/login,
      # subsequent requests carry it instead of the bearer. Closing the
      # XSS-leak window for browser-based operators while keeping bearer
      # auth alive for curl / k8s / automation.

      SESSION_COOKIE = "prouterd_session".freeze

      # True if `env`'s Cookie header carries a session id known to
      # `sessions`. Returns false when no session store is wired (the
      # SessionStore is optional infrastructure — open-mode + bearer-only
      # deploys never instantiate it).
      def cookie_session_valid?(env_or_request, sessions)
        return false unless sessions

        env = env_or_request.respond_to?(:env) ? env_or_request.env : env_or_request
        cookies = parse_cookies(env["HTTP_COOKIE"].to_s)
        sessions.valid?(cookies[SESSION_COOKIE])
      end

      # Read the session id from the request's Cookie header — used by
      # logout to revoke the right entry.
      def session_id_from(env_or_request)
        env = env_or_request.respond_to?(:env) ? env_or_request.env : env_or_request
        parse_cookies(env["HTTP_COOKIE"].to_s)[SESSION_COOKIE]
      end

      def parse_cookies(header)
        out = {}
        header.split(/;\s*/).each do |pair|
          k, v = pair.split("=", 2)
          out[k.strip] = (v || "").strip if k && !k.empty?
        end
        out
      end
    end
  end
end
