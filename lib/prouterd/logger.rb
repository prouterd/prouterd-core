require "logger"
require "json"
require "thread"

module Prouterd
  # Syslog-style daemon logger.
  #
  #   May  8 14:23:01.234: %DAEMON-6-STARTING: bind=127.0.0.1 port=8080
  #
  # Every call site supplies a `facility` (uppercase, e.g. DAEMON, RUN,
  # STORE, SCHED, WORK, API, WEBHOOK, RECOV, CONFIG, SECRET) and a
  # `mnemonic` (uppercase short tag, e.g. STARTING, RUN_FAILED,
  # HMAC_FAIL). The facility-severity-mnemonic triplet is the operator's
  # grep key and is documented one paragraph each in
  # `docs/log-messages.md`.
  #
  # Levels map to standard syslog severities (0 = highest urgency, 7 = lowest):
  #
  #     fatal   → 0  emergency
  #     error   → 3  errors
  #     warn    → 4  warnings
  #     notice  → 5  notifications
  #     info    → 6  informational
  #     debug   → 7  debugging
  #
  # Output: stdout (or any IO passed to `Logger.build`) PLUS a bounded
  # in-memory ring buffer that the shell's `show logging` command
  # reads. The ring is process-local and lossy (last N entries kept),
  # which matches the router-CLI `show logging` semantics — for
  # durable audit you keep the daemon under journald/systemd or pipe
  # stdout into a file rotated by logrotate.
  #
  # Usage:
  #
  #     log = Prouterd::Logger.build($stdout)
  #     log.info("daemon starting", facility: "DAEMON", mnemonic: "STARTING",
  #              bind: "127.0.0.1", port: 8080)
  #     log.error("storage probe failed",
  #               facility: "STORE", mnemonic: "PROBE_ERR",
  #               error: e.class.name, message: e.message)
  #
  # Components accept `logger:` kwarg and default to NullLogger so tests
  # don't need to wire anything.
  class Logger
    # name → (numeric_severity, ::Logger constant)
    LEVELS = {
      "debug"  => [7, ::Logger::DEBUG],
      "info"   => [6, ::Logger::INFO],
      "notice" => [5, ::Logger::INFO],   # ::Logger has no NOTICE; emit at INFO
      "warn"   => [4, ::Logger::WARN],
      "error"  => [3, ::Logger::ERROR],
      "fatal"  => [0, ::Logger::FATAL]
    }.freeze

    DEFAULT_LEVEL = "info".freeze
    DEFAULT_RING_SIZE = 1000

    # Process-singleton ring buffer the `show logging` command reads.
    # Each entry is a Hash {ts, severity, facility, mnemonic, message,
    # context, line}. Bounded; oldest entries drop on overflow.
    class Ring
      def initialize(capacity = DEFAULT_RING_SIZE)
        @capacity = capacity
        @entries = []
        @mutex = Mutex.new
      end

      def push(entry)
        @mutex.synchronize do
          @entries << entry
          @entries.shift if @entries.length > @capacity
        end
      end

      def tail(n = @capacity, severity: nil, facility: nil)
        @mutex.synchronize do
          rows = @entries
          rows = rows.select { |e| e[:severity] <= severity } if severity
          rows = rows.select { |e| e[:facility] == facility } if facility
          rows.last(n)
        end
      end
    end

    def self.ring
      @ring ||= Ring.new
    end

    def self.build(io = $stdout, level: nil, progname: "prouterd")
      level_name = (level || ENV["PROUTERD_LOG_LEVEL"] || DEFAULT_LEVEL).to_s.downcase
      _, level_const = LEVELS.fetch(level_name) { LEVELS["info"] }

      base = ::Logger.new(io)
      base.level = level_const
      base.progname = progname
      base.formatter = ->(_sev, _time, _pgnm, msg) { msg.end_with?("\n") ? msg : "#{msg}\n" }
      new(base)
    end

    # Canonical syslog timestamp: `MMM DD HH:MM:SS.mmm` (UTC).
    def self.format_timestamp(time)
      time.utc.strftime("%b %e %H:%M:%S.%3N")
    end

    # Render a single syslog-style log line. Public so the shell's
    # `show logging` formatter can reuse it on tail entries.
    def self.format_line(severity:, facility:, mnemonic:, message:, context:, time: Time.now)
      head = "#{format_timestamp(time)}: %#{facility}-#{severity}-#{mnemonic}: #{message}"
      return head if context.nil? || context.empty?

      pairs = context.map { |k, v| "#{k}=#{format_value(v)}" }.join(" ")
      "#{head} #{pairs}"
    end

    def self.format_value(v)
      case v
      when nil then "-"
      when Numeric, TrueClass, FalseClass then v.to_s
      when Symbol then v.to_s
      when String
        v.match?(/[\s=]/) ? v.inspect : v
      else
        JSON.dump(v)
      end
    end

    def initialize(base)
      @base = base
    end

    %w[debug info notice warn error fatal].each do |level|
      define_method(level) do |message, facility: "PROC", mnemonic: "MSG", **context|
        emit(level, facility, mnemonic, message, context)
      end
    end

    # Returns a wrapper that automatically merges baseline context
    # into every entry — useful for per-run / per-job loggers.
    def with(**baseline)
      Tagged.new(self, baseline)
    end

    private

    def emit(level_name, facility, mnemonic, message, context)
      severity, log_const = LEVELS.fetch(level_name)
      facility = facility.to_s.upcase
      mnemonic = mnemonic.to_s.upcase
      time = Time.now
      line = self.class.format_line(
        severity: severity, facility: facility, mnemonic: mnemonic,
        message: message, context: context, time: time
      )

      # Push to the ring before stdout — show-logging stays useful even
      # if stdout is closed (containerised daemons sometimes lose stdout
      # to a paused tty).
      Logger.ring.push(
        ts: time, severity: severity, facility: facility,
        mnemonic: mnemonic, message: message, context: context, line: line
      )

      @base.public_send(::Logger::SEV_LABEL[log_const].downcase, line)
    end

    class Tagged
      def initialize(parent, baseline)
        @parent = parent
        @baseline = baseline
      end

      %w[debug info notice warn error fatal].each do |level|
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
    %w[debug info notice warn error fatal].each do |level|
      define_method(level) { |_message, **_ctx| nil }
    end

    def with(**_)
      self
    end
  end
end
