require "net/http"
require "uri"
require "json"

module Prouterd
  module Iface
    # Caller for `interface http`. Invoked by `Runner::CallRunner` when a
    # block declares `type call ... use <name>` against an http interface.
    #
    # Inputs from the resolved AST::Interface:
    #   * `base-url`  — scheme + host + optional path prefix
    #   * `auth`      — AST::Auth or nil; bearer token resolved by caller
    #
    # Inputs from the per-call type_fields (already templated):
    #   * `method`    — "GET" / "POST" / "PUT" / "PATCH" / "DELETE" (default GET)
    #   * `path`      — appended to base-url. May start with /, may not.
    #   * `query`     — "k=v&k=v" string (templated whole)
    #   * `body-json` — raw string body. Sets Content-Type to application/json.
    #
    # Returns CallerResult{exit_code, output_json, stdout, stderr,
    # error_type, error_message}.
    class HttpCaller
      DEFAULT_METHOD = "GET".freeze

      CallerResult = Struct.new(
        :exit_code, :output_json, :stdout, :stderr,
        :error_type, :error_message,
        keyword_init: true
      )

      def initialize(secret_resolver: nil)
        @secret_resolver = secret_resolver
      end

      # iface — AST::Interface (the resolved outbound interface)
      # call_fields — Hash<String, String> from block type_fields, templated
      # secrets — Hash<String, String> resolved bearer tokens etc., keyed by
      #           the secret NAME declared on the interface (e.g. "JIRA_TOKEN")
      # timeout_ms — overall timeout, optional
      def call(iface:, call_fields:, secrets: {}, timeout_ms: nil)
        base_url = iface.type_fields["base-url"]
        unless base_url && !base_url.empty?
          return error("invalid_interface", "interface '#{iface.name}' has no base-url")
        end

        method = (call_fields["method"] || DEFAULT_METHOD).to_s.upcase
        path = call_fields["path"].to_s
        query = call_fields["query"].to_s
        body_json = call_fields["body-json"]

        url = build_url(base_url, path, query)

        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          return error("invalid_url", "not an http(s) URL: #{url}")
        end

        request = build_request(method, uri, body_json)
        apply_auth(request, iface, secrets)

        response = perform(uri, request, timeout_ms)
        body = response.body.to_s

        parsed_body = nil
        begin
          parsed_body = JSON.parse(body) unless body.empty?
        rescue JSON::ParserError
          # leave parsed_body nil; output stays as raw text in stdout
        end

        if response.code.to_i.between?(200, 299)
          CallerResult.new(
            exit_code: 0,
            output_json: parsed_body || { "status" => response.code.to_i, "body" => body },
            stdout: parsed_body ? "" : body,
            stderr: "",
            error_type: nil,
            error_message: nil
          )
        else
          CallerResult.new(
            exit_code: response.code.to_i,
            output_json: nil,
            stdout: parsed_body ? JSON.dump(parsed_body) : body,
            stderr: "",
            error_type: "http_status",
            error_message: "HTTP #{response.code}: #{first_line(body)}"
          )
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        error("timeout", "HTTP timeout: #{e.message}")
      rescue StandardError => e
        error("http_error", "#{e.class}: #{e.message}")
      end

      private

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

      def apply_auth(request, iface, secrets)
        auth = iface.type_fields["auth"]
        return unless auth

        token = secrets[auth.secret_name]
        return unless token && !token.empty?

        case auth.scheme
        when "bearer"
          request["authorization"] = "Bearer #{token}"
        end
      end

      def perform(uri, request, timeout_ms)
        Net::HTTP.start(uri.hostname, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: timeout_seconds(timeout_ms),
                        read_timeout: timeout_seconds(timeout_ms)) do |http|
          http.request(request)
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
        CallerResult.new(
          exit_code: nil, output_json: nil, stdout: "", stderr: message,
          error_type: type, error_message: message
        )
      end
    end
  end
end
