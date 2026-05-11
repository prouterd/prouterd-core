# frozen_string_literal: true

module Prouterd
  module API
    # In-process Prometheus-style counter/gauge registry. Renders to text
    # format on `/metrics`. Thread-safe via a single mutex.
    #
    # The minimal set that answers "what's the daemon doing right now":
    #   * runs_total{process,status}            counter
    #   * step_total{block,status}              counter
    #   * webhooks_received_total{iface,code}   counter
    #   * cron_fires_total{interface}           counter
    #   * in_flight_runs                        gauge (sourced from registry)
    #
    # Histograms (step_duration_ms) are deliberately not included — adding
    # them well requires bucket selection and either Prometheus client lib
    # or a careful reservoir. Out of v1 scope.
    class Metrics
      attr_reader :counters

      def initialize(in_flight: nil)
        @mutex = Mutex.new
        @counters = Hash.new(0)
        @in_flight = in_flight
        @started_at = Time.now.to_f
      end

      def increment(name, by: 1, **labels)
        key = [name, labels.sort.to_h]
        @mutex.synchronize { @counters[key] += by }
      end

      def render
        lines = []
        lines << "# HELP prouterd_uptime_seconds Time since the daemon started."
        lines << "# TYPE prouterd_uptime_seconds gauge"
        lines << "prouterd_uptime_seconds #{(Time.now.to_f - @started_at).round(3)}"

        if @in_flight
          lines << "# HELP prouterd_in_flight_runs Currently executing runs."
          lines << "# TYPE prouterd_in_flight_runs gauge"
          lines << "prouterd_in_flight_runs #{@in_flight.in_flight_count}"
        end

        grouped = @mutex.synchronize { @counters.dup }.group_by { |(name, _), _| name }
        grouped.each do |name, entries|
          lines << "# HELP prouterd_#{name} Cumulative count."
          lines << "# TYPE prouterd_#{name} counter"
          entries.each do |(_n, labels), value|
            label_str = labels.empty? ? "" : "{#{labels.map { |k, v| %(#{k}="#{escape(v.to_s)}") }.join(',')}}"
            lines << "prouterd_#{name}#{label_str} #{value}"
          end
        end

        lines.join("\n") + "\n"
      end

      private

      def escape(value)
        value.gsub("\\", "\\\\").gsub('"', '\\"').gsub("\n", '\\n')
      end
    end
  end
end
