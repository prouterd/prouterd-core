# frozen_string_literal: true

require "json"
require "faye/websocket"

module Prouterd
  module API
    # Long-lived WebSocket endpoint exposing the Prouterd::Events bus to
    # external consumers — the web console, monitoring agents, custom
    # dashboards, anything that wants live state without polling.
    #
    # Wire protocol: subscribe / unsubscribe / event frames. Topic names
    # on the WS side:
    #
    #   "runs"          every run.created / run.updated, all processes
    #   "run:<uid>"     run + step events for that specific run
    #   "logs:<uid>"    log.appended for that run
    #   "system"        config commits, rollbacks, save-as-boot — drives
    #                   live refresh of every config-derived window
    #                   (interfaces / blocks / routes / queues / policies
    #                   / secrets / tools / config / diff)
    #
    # The internal `Prouterd::Events` topics (`:run_created`, `:step_updated`,
    # `:log_appended`, `:config_changed`, …) are mapped to the wire topics
    # here so external clients don't need to know about Storage::* objects.
    #
    # Auth: same bearer-token rule as the rest of /v1. When PROUTERD_ADMIN_TOKEN
    # is unset, the endpoint is open (matches App's behaviour).
    #
    # `socket` only needs to expose `#send(string)` and `#close(code, reason)`
    # — production wires Faye::WebSocket; tests inject a capture double.
    class EventsWebSocket
      def self.handle(env, events:, admin_token: nil, dispatcher: nil, sessions: nil, logger: nil)
        ws   = Faye::WebSocket.new(env)
        conn = new(ws,
                   env: env, events: events,
                   admin_token: admin_token,
                   dispatcher: dispatcher,
                   sessions: sessions,
                   logger: logger)
        ws.on(:open)    { conn.on_open }
        ws.on(:message) { |e| conn.on_message(e.data) }
        ws.on(:close)   { conn.on_close }
        ws.rack_response
      end

      def initialize(socket, env:, events:, admin_token: nil, dispatcher: nil, sessions: nil, logger: nil)
        @socket          = socket
        @env             = env
        @events          = events
        @admin_token     = admin_token
        @dispatcher      = dispatcher
        @sessions        = sessions
        @logger          = logger
        @client_topics   = {}      # wire_topic_string => true
        @internal_subs   = []
        @send_mutex      = Mutex.new
        @subs_mutex      = Mutex.new
      end

      # ----- lifecycle -----

      def on_open
        unless authenticated?
          send_error(code: "unauthorized", message: "missing or invalid bearer token")
          @socket.close(4401, "unauthorized") if @socket.respond_to?(:close)
          return
        end

        attach_internal_subscribers
        send_message(type: "hello", payload: { version: Prouterd::VERSION })
      end

      def on_message(raw)
        msg =
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return send_error(code: "invalid_json", message: "could not parse message")
          end

        case msg["type"]
        when "subscribe"   then handle_subscribe(msg)
        when "unsubscribe" then handle_unsubscribe(msg)
        when "call"        then handle_call(msg)
        when "ping"        then send_message(reply_to: msg["id"], type: "pong")
        else send_error(code: "unknown_type",
                        message: "unknown message type: #{msg["type"].inspect}",
                        reply_to: msg["id"])
        end
      end

      def on_close
        @subs_mutex.synchronize do
          @internal_subs.each { |h| @events.unsubscribe(h) }
          @internal_subs.clear
          @client_topics.clear
        end
      end

      # ----- inspection (used by tests) -----

      def subscribed_topics
        @subs_mutex.synchronize { @client_topics.keys.dup }
      end

      private

      def authenticated?
        return true if @admin_token.nil? || @admin_token.empty?
        # Cookie session set by /v1/login wins. Fall back to bearer.
        return true if Auth.cookie_session_valid?(@env, @sessions)

        provided = Auth.token_from(@env)
        return false if provided.nil? || provided.empty?

        Rack::Utils.secure_compare(provided, @admin_token)
      end

      def attach_internal_subscribers
        @subs_mutex.synchronize do
          @internal_subs << @events.subscribe(:run_created)     { |_, p| route_run("run.created", p) }
          @internal_subs << @events.subscribe(:run_updated)     { |_, p| route_run("run.updated", p) }
          @internal_subs << @events.subscribe(:step_created)    { |_, p| route_step("step.created", p) }
          @internal_subs << @events.subscribe(:step_updated)    { |_, p| route_step("step.updated", p) }
          @internal_subs << @events.subscribe(:log_appended)    { |_, p| route_log(p) }
          @internal_subs << @events.subscribe(:config_changed)  { |_, p| route_config_changed(p) }
        end
      end

      def handle_subscribe(msg)
        topic = msg.dig("payload", "topic")
        unless topic.is_a?(String) && !topic.empty?
          return send_error(code: "invalid_payload",
                            message: "subscribe requires payload.topic",
                            reply_to: msg["id"])
        end

        already = nil
        @subs_mutex.synchronize do
          already = @client_topics.key?(topic)
          @client_topics[topic] = true
        end

        send_message(reply_to: msg["id"],
                     type:     already ? "subscribe.already" : "subscribe.ok",
                     payload:  { topic: topic })
      end

      def handle_unsubscribe(msg)
        topic = msg.dig("payload", "topic")
        unless topic.is_a?(String) && !topic.empty?
          return send_error(code: "invalid_payload",
                            message: "unsubscribe requires payload.topic",
                            reply_to: msg["id"])
        end

        @subs_mutex.synchronize { @client_topics.delete(topic) }
        send_message(reply_to: msg["id"], type: "unsubscribe.ok", payload: { topic: topic })
      end

      # WS-RPC: dispatches `{ id, type:"call", payload:{ method, args } }`
      # through the RpcDispatcher and replies with
      # `{ reply_to, type:"reply"|"error", payload }`. Lets the browser
      # console talk to the daemon over a single socket without using
      # HTTP /v1/* for individual data fetches.
      def handle_call(msg)
        reply_to = msg["id"]
        unless @dispatcher
          return send_error(code: "unsupported",
                            message: "RPC not configured on this socket",
                            reply_to: reply_to)
        end

        method = msg.dig("payload", "method")
        unless method.is_a?(String) && !method.empty?
          return send_error(code: "invalid_payload",
                            message: "call requires payload.method",
                            reply_to: reply_to)
        end

        args = msg.dig("payload", "args") || {}
        unless args.is_a?(Hash)
          return send_error(code: "invalid_payload",
                            message: "call payload.args must be an object",
                            reply_to: reply_to)
        end

        result = @dispatcher.call(method, args)
        send_message(reply_to: reply_to,
                     type:     result[:type],
                     payload:  result[:payload])
      end

      # ----- internal-event routing -----

      def route_run(type, payload)
        run = payload[:run]
        return unless run

        body = run_to_wire(run)
        deliver_if_subscribed("runs",          type, body)
        deliver_if_subscribed("run:#{run.uid}", type, body)
      end

      def route_step(type, payload)
        step    = payload[:step]
        run_uid = payload[:run_uid]
        return unless step && run_uid

        body = step_to_wire(step).merge(run_uid: run_uid)
        deliver_if_subscribed("run:#{run_uid}", type, body)
      end

      def route_log(payload)
        run_uid = payload[:run_uid]
        return unless run_uid

        deliver_if_subscribed("logs:#{run_uid}", "log.appended", log_to_wire(payload))
      end

      def route_config_changed(payload)
        deliver_if_subscribed(
          "system", "config.changed",
          {
            reason:         payload[:reason],
            running_commit: payload[:running_commit],
            startup_commit: payload[:startup_commit]
          }
        )
      end

      def deliver_if_subscribed(topic, type, payload)
        return unless @subs_mutex.synchronize { @client_topics[topic] }

        send_raw(topic: topic, type: type, payload: payload)
      end

      # ----- payload shaping -----

      def run_to_wire(run)
        {
          uid:            run.uid,
          process_name:   run.process_name,
          interface_name: run.interface_name,
          status:         run.status,
          commit_id:      run.process_config_commit_id,
          replay_of:      run.replay_of_run_id,
          started_at:     run.started_at,
          finished_at:    run.finished_at,
          created_at:     run.created_at,
          duration_ms:    run.duration_ms,
          error_summary:  run.error_summary
        }
      end

      def step_to_wire(step)
        {
          id:            step.id,
          block_name:    step.block_name,
          status:        step.status,
          attempt:       step.attempt,
          image:         step.image,
          exit_code:     step.exit_code,
          error_type:    step.error_type,
          error_message: step.error_message,
          started_at:    step.started_at,
          finished_at:   step.finished_at,
          duration_ms:   step.duration_ms
        }
      end

      def log_to_wire(payload)
        {
          run_uid:    payload[:run_uid],
          step_id:    payload[:step_id],
          stream:     payload[:stream],
          content:    payload[:content],
          created_at: payload[:created_at]
        }
      end

      # ----- wire I/O -----

      def send_message(type:, payload: {}, reply_to: nil)
        msg = { type: type, payload: payload }
        msg[:reply_to] = reply_to if reply_to
        send_raw(msg)
      end

      def send_error(code:, message:, reply_to: nil)
        send_message(type: "error", payload: { code: code, message: message }, reply_to: reply_to)
      end

      def send_raw(obj)
        @send_mutex.synchronize { @socket.send(JSON.dump(obj)) }
      rescue StandardError => e
        @logger&.error("[ws/events] send error: #{e.class}: #{e.message}")
      end
    end
  end
end
