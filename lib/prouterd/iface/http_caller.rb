require "net/http"
require "uri"
require "json"

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
    # The resolved bearer token is taken from `request.env[secret_name]`
    # (the orchestrator already injected it there via build_env).
    class HttpCaller
      DEFAULT_METHOD = "GET".freeze

      def run(request)
        started_at = Time.now.utc
        result = perform_run(request)
        finished_at = Time.now.utc
        Runner::ExecutionResult.new(
          exit_code:     result[:exit_code],
          stdout:        result[:stdout].to_s,
          stderr:        result[:stderr].to_s,
          output_json:   result[:output_json],
          artifacts:     [],
          error_type:    result[:error_type],
          error_message: result[:error_message],
          duration_ms:   ((finished_at - started_at) * 1000).to_i,
          started_at:    started_at.iso8601(3),
          finished_at:   finished_at.iso8601(3)
        )
      end

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

        http_request = build_request(method, uri, body)
        apply_auth(http_request, request.field("auth"), request.env || {})

        response = perform(uri, http_request, request.timeout_ms)
        body_text = response.body.to_s

        parsed_body = nil
        begin
          parsed_body = JSON.parse(body_text) unless body_text.empty?
        rescue JSON::ParserError
          # raw text falls into stdout below
        end

        if response.code.to_i.between?(200, 299)
          {
            exit_code:   0,
            output_json: parsed_body || { "status" => response.code.to_i, "body" => body_text },
            stdout:      parsed_body ? "" : body_text,
            stderr:      "",
            error_type:  nil, error_message: nil
          }
        else
          {
            exit_code:     response.code.to_i,
            output_json:   nil,
            stdout:        parsed_body ? JSON.dump(parsed_body) : body_text,
            stderr:        "",
            error_type:    "http_status",
            error_message: "HTTP #{response.code}: #{first_line(body_text)}"
          }
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        error("timeout", "HTTP timeout: #{e.message}")
      rescue StandardError => e
        error("http_error", "#{e.class}: #{e.message}")
      end

      def build_url(base, path, query)
        url = base.dup
        url.chomp!("/") if !path.empty? && path.start_with?("/")
        url << path unless path.empty?
        url << (url.include?("?") ? "&" : "?") << query unless query.empty?
        url
      end

      def build_request(method, uri, body_json)
        klass = case method
                when "GET"    then Net::HTTP::Get
                when "POST"   then Net::HTTP::Post
                when "PUT"    then Net::HTTP::Put
                when "PATCH"  then Net::HTTP::Patch
                when "DELETE" then Net::HTTP::Delete
                else
                  raise ArgumentError, "unsupported HTTP method: #{method}"
                end

        request = klass.new(uri.request_uri)
        if body_json && !body_json.empty?
          request["content-type"] = "application/json"
          request.body = body_json
        end
        request
      end

      def apply_auth(http_request, auth, env)
        return unless auth

        token = env[auth.secret_name]
        return unless token && !token.empty?

        case auth.scheme
        when "bearer"
          http_request["authorization"] = "Bearer #{token}"
        end
      end

      def perform(uri, http_request, timeout_ms)
        Net::HTTP.start(uri.hostname, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: timeout_seconds(timeout_ms),
                        read_timeout: timeout_seconds(timeout_ms)) do |http|
          http.request(http_request)
        end
      end

      def timeout_seconds(timeout_ms)
        return 30 unless timeout_ms

        [(timeout_ms.to_f / 1000.0), 1].max
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
