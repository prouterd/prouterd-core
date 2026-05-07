require "json"
require "stringio"

module Prouterd
  module API
    # Dispatches WS-RPC `call` frames into the same V1 handlers that
    # back HTTP /v1/*. Each entry in METHODS turns the args hash into a
    # FakeRequest that V1 reads (params + body), then translates the
    # Rack response triple back into a `reply` or `error` payload.
    #
    # The browser console talks to the daemon over a single WebSocket
    # via this dispatcher — see prouterd-web's assets/ws_client.js. The
    # HTTP /v1/* surface stays in place untouched for curl / k8s probes /
    # other tooling; both surfaces invoke the same V1 methods, so there
    # is no duplicate business logic.
    #
    # Wire format (handled by EventsWebSocket):
    #   browser → daemon: { id, type: "call", payload: { method, args } }
    #   daemon → browser: { reply_to, type: "reply"|"error", payload }
    class RpcDispatcher
      ERROR_FOR_STATUS = {
        400 => "bad_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        409 => "conflict",
        410 => "gone",
        413 => "payload_too_large",
        422 => "unprocessable",
        503 => "unavailable"
      }.freeze

      def initialize(v1:, app:, store:)
        @v1    = v1
        @app   = app
        @store = store
      end

      # Returns { type: "reply", payload: ... } or
      #         { type: "error", payload: { code:, message: } }.
      # Never raises; uncaught errors come back as code:"internal".
      def call(method, args)
        args ||= {}
        case method
        when "status"             then ok(@app.status_payload)

        when "processes.list"     then forward_json { @v1.get_processes(req(args)) }
        when "processes.get"      then forward_json { @v1.get_process(req(args), str(args, "name")) }
        when "processes.trigger"  then forward_json { @v1.post_process_trigger(req(args, body: args["event"] || {}), str(args, "name")) }

        when "interfaces.list"    then forward_json { @v1.get_interfaces(req(args)) }
        when "queues.list"        then forward_json { @v1.get_queues(req(args)) }
        when "policies.list"      then forward_json { @v1.get_policies(req(args)) }
        when "secrets.list"       then forward_json { @v1.get_secrets(req(args)) }

        when "runs.list"          then forward_json { @v1.get_runs(req(args)) }
        when "runs.get"           then forward_json { @v1.get_run(req(args), str(args, "uid")) }
        when "runs.cancel"        then forward_json { @v1.post_run_cancel(req(args), str(args, "uid")) }
        when "runs.replay"        then forward_json { @v1.post_run_replay(req(args, body: replay_body(args)), str(args, "uid")) }
        when "runs.logs"          then forward_json { @v1.get_run_logs(req(args), str(args, "uid")) }
        when "runs.artifacts"     then forward_json { @v1.get_run_artifacts(req(args), str(args, "uid")) }

        when "config.running"     then forward_text { @v1.get_config_running(req(args)) }
        when "config.startup"     then forward_text { @v1.get_config_startup(req(args)) }
        when "config.commits"     then forward_json { @v1.get_config_commits(req(args)) }
        when "config.commit"      then forward_json { @v1.get_config_commit(req(args), str(args, "id")) }
        when "config.rollback"    then forward_json { @v1.post_config_rollback(req(args, body: { "commit_id" => args["commit_id"] })) }
        when "config.save_boot"   then forward_json { @v1.post_config_save_boot(req(args)) }

        when "trace"              then forward_json { @v1.post_trace(req(args, body: trace_body(args))) }

        else
          err("unknown_method", "no such RPC method: #{method}")
        end
      rescue StandardError => e
        err("internal", "#{e.class}: #{e.message}")
      end

      private

      def ok(payload)
        { type: "reply", payload: payload }
      end

      def err(code, message)
        { type: "error", payload: { code: code, message: message } }
      end

      # Build a FakeRequest from RPC args. Every key in args becomes a
      # query-style param (string-keyed), so V1 methods that read
      # request.params["..."] keep working. `body:` (if given) is
      # JSON-serialized so V1 methods that call read_body /
      # parse_json_body see the same shape they used to over HTTP.
      def req(args, body: nil)
        FakeRequest.new(params: stringify(args), body: body)
      end

      def stringify(h)
        out = {}
        (h || {}).each do |k, v|
          out[k.to_s] = v.is_a?(Hash) ? stringify(v) : v
        end
        out
      end

      def str(args, key)
        v = args[key] || args[key.to_sym]
        v.nil? ? nil : v.to_s
      end

      def replay_body(args)
        out = {}
        out["from_block"] = args["from_block"] if args["from_block"]
        out
      end

      def trace_body(args)
        out = { "event" => args["event"] || {} }
        out["interface"] = args["interface"] if args["interface"]
        out
      end

      # Converts a JSON Rack triple into a `reply` payload. Status >= 400
      # produces an `error` frame with a code derived from the status.
      def forward_json
        status, _headers, body = yield
        text = read_rack_body(body)
        if status >= 200 && status < 300
          payload =
            begin
              JSON.parse(text)
            rescue JSON::ParserError
              return err("internal", "non-JSON success body from V1")
            end
          ok(payload)
        else
          payload = (JSON.parse(text) rescue {})
          code    = ERROR_FOR_STATUS[status] || "internal"
          msg     = payload["error"] || "rpc error (status #{status})"
          out     = { code: code, message: msg }
          out[:details] = payload["details"] if payload["details"]
          { type: "error", payload: out }
        end
      end

      # config.running / config.startup return plain text bodies
      # (the rendered DSL). Wrap them as a reply payload that's a
      # bare string so the SPA's adapter receives the same shape it
      # used to over HTTP (it reads response.text directly).
      def forward_text
        status, _headers, body = yield
        text = read_rack_body(body)
        if status >= 200 && status < 300
          ok(text)
        else
          payload = (JSON.parse(text) rescue {})
          err(ERROR_FOR_STATUS[status] || "internal",
              payload["error"] || "rpc error (status #{status})")
        end
      end

      def read_rack_body(body)
        return body if body.is_a?(String)
        out = +""
        body.each { |chunk| out << chunk }
        body.close if body.respond_to?(:close)
        out
      end
    end

    # Minimal Rack::Request stand-in for RPC dispatch. Surfaces just
    # enough of the interface that V1 methods touch:
    #   - params (string-keyed query/form params)
    #   - body (IO of the JSON-encoded body, if any)
    #   - get_header (no headers, returns nil)
    #   - content_length / request_method (for completeness)
    class FakeRequest
      def initialize(params: {}, body: nil)
        @params    = params || {}
        @body_str  = body.nil? ? nil : JSON.dump(body)
        @body_io   = nil
      end

      def params
        @params
      end

      def body
        @body_io ||= StringIO.new(@body_str || "")
      end

      def get_header(_name)
        nil
      end

      def content_length
        @body_str ? @body_str.bytesize : 0
      end

      def request_method
        @body_str ? "POST" : "GET"
      end
    end
  end
end
