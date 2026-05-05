require "net/http"
require "uri"
require "json"

module Prouterd
  module Iface
    # Thin Net::HTTP wrapper shared by HttpCaller, LlmCaller, and any
    # future iface plugin that talks JSON over HTTP. Centralises:
    #
    #   * method → Net::HTTP::* dispatch
    #   * SSL toggle from URI scheme
    #   * Connect/read timeout from `timeout_ms`
    #   * Response body capture + best-effort JSON parse
    #   * Typed error categorisation (TimeoutError / RequestError) so
    #     each caller maps to its own user-facing error_type label
    #     ("timeout" + "http_error" for http; "timeout" + "llm_error"
    #     for llm; etc.)
    #
    # Callers stay focused on what's actually unique to their iface
    # type: URL building, auth, request body shape, response shape.
    module HttpClient
      module_function

      # Captured response. `body_json` is the parsed JSON Hash/Array if
      # the body parsed cleanly, otherwise nil (raw text still in
      # body_text). Caller decides whether 2xx-only-counts-as-success.
      Response = Struct.new(:status, :body_text, :body_json, keyword_init: true)

      # Wire-level transport problem (DNS, connect refused, TLS, parse,
      # generic IOError). Caller maps to its own error_type.
      RequestError = Class.new(StandardError)

      # Open or read timeout. Distinct from RequestError so callers can
      # surface a dedicated "timeout" error_type that retry-when can match.
      TimeoutError = Class.new(StandardError)

      DEFAULT_TIMEOUT_SECONDS = 30

      METHOD_MAP = {
        "GET"    => Net::HTTP::Get,
        "POST"   => Net::HTTP::Post,
        "PUT"    => Net::HTTP::Put,
        "PATCH"  => Net::HTTP::Patch,
        "DELETE" => Net::HTTP::Delete
      }.freeze

      # Perform an HTTP request and return a Response.
      #
      # method     — string ("GET" / "POST" / ...). ArgumentError on unknown.
      # uri        — URI::HTTP or URI::HTTPS (caller validates scheme).
      # headers    — Hash<String, String>. content-type for JSON, auth headers, etc.
      # body       — String (already serialized) or nil.
      # timeout_ms — Integer (ms) for both open + read timeout, or nil for
      #              the DEFAULT_TIMEOUT_SECONDS default.
      def request(method:, uri:, headers: {}, body: nil, timeout_ms: nil)
        klass = METHOD_MAP[method.to_s.upcase] or
          raise ArgumentError, "unsupported HTTP method: #{method}"

        http_request = klass.new(uri.request_uri)
        headers.each { |k, v| http_request[k.to_s] = v.to_s }
        http_request.body = body if body && !body.empty?

        timeout_s = timeout_seconds(timeout_ms)
        raw = Net::HTTP.start(uri.hostname, uri.port,
                              use_ssl: uri.scheme == "https",
                              open_timeout: timeout_s,
                              read_timeout: timeout_s) do |http|
          http.request(http_request)
        end

        body_text = raw.body.to_s
        body_json = nil
        begin
          body_json = JSON.parse(body_text) unless body_text.empty?
        rescue JSON::ParserError
          # leave nil; caller can fall back to body_text
        end

        Response.new(status: raw.code.to_i, body_text: body_text, body_json: body_json)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, e.message
      rescue ArgumentError
        raise
      rescue StandardError => e
        raise RequestError, "#{e.class}: #{e.message}"
      end

      # Convert ms → seconds with a 1-second floor so the host doesn't
      # connect-storm a misconfigured timeout. nil → default.
      def timeout_seconds(timeout_ms, default: DEFAULT_TIMEOUT_SECONDS)
        return default unless timeout_ms

        [(timeout_ms.to_f / 1000.0), 1].max
      end
    end
  end
end
