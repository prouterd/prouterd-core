require "logger"
require "json"

module Prouterd
  # Thin wrapper around stdlib `Logger` with two production-leaning
  # defaults:
  #
  #   1. Single-line, structured-friendly output. Each entry has a
  #      timestamp, level, and message; extra context (run_id, block,
  #      interface, ...) is appended as `key=value` pairs so an
  #      operator can grep without an extra parser.
  #
  #   2. Level controlled by `PROUTERD_LOG_LEVEL` (debug / info / warn /
  #      error / fatal — default info). Controlled per-run uniformly,
  #      no per-component knobs (those are debugging headaches in prod).
  #
  # Usage:
  #
  #     log = Prouterd::Logger.build($stdout)
  #     log.info("orchestrator: run started", run_id: run.uid, process: "p")
  #     log.error("orchestrator: run crashed",
  #               run_id: run.uid, error: e.class.name, message: e.message)
  #
  # Components accept `logger:` kwarg and default to a NullLogger so
  # tests don't need to wire anything.
  class Logger
    LEVELS = {
      "debug" => ::Logger::DEBUG,
      "info"  => ::Logger::INFO,
      "warn"  => ::Logger::WARN,
      "error" => ::Logger::ERROR,
      "fatal" => ::Logger::FATAL
    }.freeze

    DEFAULT_LEVEL = "info".freeze

    def self.build(io = $stdout, level: nil, progname: "prouterd")
      level_name = (level || ENV["PROUTERD_LOG_LEVEL"] || DEFAULT_LEVEL).to_s.downcase
      level_const = LEVELS[level_name] || ::Logger::INFO

      base = ::Logger.new(io)
      base.level = level_const
      base.progname = progname
      base.formatter = method(:format_line)
      new(base)
    end

    def self.format_line(severity, time, progname, message)
      ts = time.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      "#{ts} #{severity.ljust(5)} #{progname}: #{message}\n"
    end

    def initialize(base)
      @base = base
    end

    %w[debug info warn error fatal].each do |level|
      define_method(level) do |message, **context|
        @base.public_send(level, render(message, context))
      end
    end

    # Returns a wrapper that automatically merges baseline context
    # into every entry — useful for per-run / per-job loggers.
    def with(**baseline)
      Tagged.new(self, baseline)
    end

    private

    def render(message, context)
      return message.to_s if context.nil? || context.empty?

      pairs = context.map { |k, v| "#{k}=#{format_value(v)}" }.join(" ")
      "#{message} #{pairs}"
    end

    def format_value(v)
      case v
      when nil then "-"
      when Numeric, TrueClass, FalseClass then v.to_s
      when Symbol then v.to_s
      when String
        # Quote strings that contain spaces or `=` so the kv shape stays parseable.
        v.match?(/[\s=]/) ? v.inspect : v
      else
        JSON.dump(v)
      end
    end

    class Tagged
      def initialize(parent, baseline)
        @parent = parent
        @baseline = baseline
      end

      %w[debug info warn error fatal].each do |level|
        define_method(level) do |message, **context|
          @parent.public_send(level, message, **@baseline.merge(context))
        end
      end

      def with(**extra)
        Tagged.new(@parent, @baseline.merge(extra))
      end
    end
  end

  # No-op logger — used as the default in components so tests don't
  # need to construct anything. Same surface area as `Logger`.
  class NullLogger
    %w[debug info warn error fatal].each do |level|
      define_method(level) { |_message, **_ctx| nil }
    end

    def with(**_)
      self
    end
  end
end
