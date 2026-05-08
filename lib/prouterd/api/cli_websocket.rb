require "json"
require "stringio"
require "faye/websocket"

module Prouterd
  module API
    # WebSocket endpoint for interactive CLI sessions over the network.
    # Each connection is bound to a session_id (extracted from the URL
    # path /v1/cli/:session_id). The server keeps a per-session
    # Shell::Session in memory so config-mode and the mode_stack persist
    # across commands; if the same session_id reconnects, it resumes the
    # same Session.
    #
    # Wire protocol:
    #
    #   client → server:
    #     { id: "...", type: "command.exec", payload: { command: "..." } }
    #     { id: "...", type: "ping" }
    #
    #   server → client:
    #     { type: "hello", payload: { session_id, prompt } }
    #     { reply_to, type: "command.output",   payload: { chunk, stream } }
    #     { reply_to, type: "command.complete", payload: { exit_code, prompt } }
    #     { reply_to, type: "error",            payload: { code, message } }
    class CliWebSocket
      # Process-wide registry of CLI sessions, keyed by session_id. Each
      # bucket has its own mutex so concurrent commands within a single
      # session serialize, but distinct sessions run in parallel.
      @sessions = {}
      @sessions_mutex = Mutex.new

      class << self
        def handle(env, session_id:, store:, admin_token: nil, sessions: nil, logger: nil)
          ws   = Faye::WebSocket.new(env)
          conn = new(ws,
                     env:         env,
                     session_id:  session_id,
                     store:       store,
                     admin_token: admin_token,
                     sessions:    sessions,
                     logger:      logger)
          ws.on(:open)    { conn.on_open }
          ws.on(:message) { |e| conn.on_message(e.data) }
          ws.on(:close)   { conn.on_close }
          ws.rack_response
        end

        def session_bucket_for(session_id, store)
          @sessions_mutex.synchronize do
            @sessions[session_id] ||= begin
              session = Prouterd::Shell::Session.new(store: store)
              session.mode_stack << Prouterd::Shell::Modes::Privileged.new
              { session: session, mutex: Mutex.new }
            end
          end
        end

        # Test helper: clear the in-memory session registry.
        def reset_sessions!
          @sessions_mutex.synchronize { @sessions.clear }
        end
      end

      def initialize(socket, env:, session_id:, store:, admin_token: nil, sessions: nil, logger: nil)
        @socket      = socket
        @env         = env
        @session_id  = session_id
        @store       = store
        @admin_token = admin_token
        @sessions    = sessions
        @logger      = logger
        @send_mutex  = Mutex.new
      end

      # ----- lifecycle -----

      def on_open
        unless authenticated?
          send_error(code: "unauthorized", message: "missing or invalid bearer token")
          @socket.close(4401, "unauthorized") if @socket.respond_to?(:close)
          return
        end

        bucket = self.class.session_bucket_for(@session_id, @store)
        send_message(type: "hello", payload: {
          session_id: @session_id,
          prompt:     prompt_for(bucket[:session])
        })
      end

      def on_message(raw)
        msg =
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return send_error(code: "invalid_json", message: "could not parse message")
          end

        case msg["type"]
        when "command.exec" then handle_command_exec(msg)
        when "ping"         then send_message(reply_to: msg["id"], type: "pong")
        else send_error(code: "unknown_type",
                        message: "unknown message type: #{msg["type"].inspect}",
                        reply_to: msg["id"])
        end
      end

      # Sessions intentionally outlive the WS connection — same session_id
      # can reconnect later and resume the mode_stack / candidate config.
      def on_close
        # no-op
      end

      private

      def authenticated?
        return true if @admin_token.nil? || @admin_token.empty?
        return true if Auth.cookie_session_valid?(@env, @sessions)

        provided = Auth.token_from(@env)
        return false if provided.nil? || provided.empty?

        Rack::Utils.secure_compare(provided, @admin_token)
      end

      def handle_command_exec(msg)
        reply_to = msg["id"]
        command  = msg.dig("payload", "command")
        unless command.is_a?(String) && !command.empty?
          return send_error(code:     "invalid_payload",
                            message:  "command.exec requires payload.command",
                            reply_to: reply_to)
        end

        bucket    = self.class.session_bucket_for(@session_id, @store)
        out       = StringIO.new
        err       = StringIO.new
        exit_code = 0

        bucket[:mutex].synchronize do
          shell = Prouterd::Shell::Shell.new(
            session:     bucket[:session],
            input:       StringIO.new,
            output:      out,
            error:       err,
            interactive: false,
            banner:      false
          )
          begin
            exit_code = shell.execute_one(command)
          rescue Prouterd::Shell::ShellError => e
            err.puts "% #{e.message}"
            exit_code = 1
          rescue StandardError => e
            err.puts "% #{e.class}: #{e.message}"
            exit_code = 1
          end
        end

        emit_chunks(out.string, stream: "stdout", reply_to: reply_to)
        emit_chunks(err.string, stream: "stderr", reply_to: reply_to)

        send_message(reply_to: reply_to,
                     type:     "command.complete",
                     payload:  {
                       exit_code: exit_code,
                       prompt:    prompt_for(bucket[:session])
                     })
      end

      def emit_chunks(text, stream:, reply_to:)
        return if text.nil? || text.empty?

        text.each_line do |line|
          send_message(reply_to: reply_to,
                       type:     "command.output",
                       payload:  { chunk: line, stream: stream })
        end
      end

      def prompt_for(session)
        mode = session.mode_stack.last
        suffix = mode.respond_to?(:prompt_suffix) ? mode.prompt_suffix : "#"
        "#{session.hostname}#{suffix} "
      end

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
        @logger&.error("[ws/cli] send error: #{e.class}: #{e.message}")
      end
    end
  end
end
