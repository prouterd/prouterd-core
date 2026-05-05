require "uri"
require "json"
require_relative "http_client"
require_relative "caller_timing"

module Prouterd
  module Iface
    # Caller for `interface http`. Invoked by `Runner::CallRunner` when a
    # block declares `interface http <name>`.
    #
    # Reads from `request.type_fields` (orchestrator merged the iface body
    # and the templated per-call fields):
    #   * `base-url`  — required; scheme + host + optional path prefix
    #   * `auth`      — AST::Auth or nil; bearer token name resolved from env
    #   * `method`    — "GET" / "POST" / "PUT" / "PATCH" / "DELETE" (default GET)
    #   * `path`      — appended to base-url. May start with /, may not.
    #   * `query`     — "k=v&k=v" string
    #   * `body-json` — raw string body. Sets Content-Type to application/json.
    #
    # Wire-level work — Net::HTTP, timeouts, JSON parse — lives in the
    # shared `Iface::HttpClient`. This class only carries the iface-specific
    # logic: URL composition, auth header attachment, and 2xx classification.
    class HttpCaller
      include CallerTiming

      DEFAULT_METHOD = "GET".freeze

      private

      def perform_run(request)
        base_url = request.field("base-url").to_s
        return error("invalid_interface", "interface missing base-url") if base_url.empty?

        method = (request.field("method") || DEFAULT_METHOD).to_s.upcase
        path   = request.field("path").to_s
        query  = request.field("query").to_s
        body   = request.field("body-json")

        url = build_url(base_url, path, query)
        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          return error("invalid_url", "not an http(s) URL: #{url}")
        end

        headers = {}
        headers["content-type"] = "application/json" if body && !body.empty?
        apply_auth(headers, request.field("auth"), request.env || {})

        response = HttpClient.request(method: method, uri: uri,
                                      headers: headers, body: body,
                                      timeout_ms: request.timeout_ms)

        if response.status.between?(200, 299)
          {
            exit_code:   0,
            output_json: response.body_json || { "status" => response.status, "body" => response.body_text },
            stdout:      response.body_json ? "" : response.body_text,
            stderr:      "",
            error_type:  nil, error_message: nil
          }
        else
          {
            exit_code:     response.status,
            output_json:   nil,
            stdout:        response.body_json ? JSON.dump(response.body_json) : response.body_text,
            stderr:        "",
            error_type:    "http_status",
            error_message: "HTTP #{response.status}: #{first_line(response.body_text)}"
          }
        end
      rescue HttpClient::TimeoutError => e
        error("timeout", "HTTP timeout: #{e.message}")
      rescue HttpClient::RequestError => e
        error("http_error", e.message)
      rescue ArgumentError => e
        error("http_error", e.message)
      end

      def build_url(base, path, query)
        url = base.dup
        url.chomp!("/") if !path.empty? && path.start_with?("/")
        url << path unless path.empty?
        url << (url.include?("?") ? "&" : "?") << query unless query.empty?
        url
      end

      def apply_auth(headers, auth, env)
        return unless auth

        token = env[auth.secret_name]
        return unless token && !token.empty?

        case auth.scheme
        when "bearer"
          headers["authorization"] = "Bearer #{token}"
        end
      end

      def first_line(s)
        s.lines.first.to_s.chomp
      end

      def error(type, message)
        { exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message }
      end
    end
  end
end
