# frozen_string_literal: true

module Prouterd
  module Runner
    module IOLimits
      CHUNK_SIZE = 64 * 1024
      DEFAULT_LOG_CAPTURE_BYTES = 1 * 1024 * 1024
      DEFAULT_OUTPUT_CAPTURE_BYTES = 4 * 1024 * 1024

      module_function

      def log_capture_bytes
        env_limit("PROUTERD_LOG_CAPTURE_BYTES", DEFAULT_LOG_CAPTURE_BYTES)
      end

      def output_capture_bytes
        env_limit("PROUTERD_MAX_OUTPUT_BYTES", DEFAULT_OUTPUT_CAPTURE_BYTES)
      end

      def read_stream(io, cap: log_capture_bytes)
        buffer = String.new(encoding: Encoding::BINARY)
        truncated = false
        while (chunk = io.read(CHUNK_SIZE))
          truncated ||= !append_capped(buffer, chunk.b, cap)
        end
        buffer.force_encoding(Encoding::UTF_8)
        buffer.scrub!("?")
        buffer << "\n...[truncated to #{cap} bytes]" if truncated
        buffer
      rescue IOError
        ""
      end

      def read_file(path, cap: output_capture_bytes)
        buffer = String.new(encoding: Encoding::BINARY)
        total = 0
        File.open(path, "rb") do |f|
          while (chunk = f.read(CHUNK_SIZE))
            total += chunk.bytesize
            return [false, nil, "output file exceeds #{cap} bytes"] if total > cap

            buffer << chunk
          end
        end
        buffer.force_encoding(Encoding::UTF_8)
        [true, buffer, nil]
      end

      def append_capped(buffer, chunk, cap)
        if (buffer.bytesize + chunk.bytesize) <= cap
          buffer << chunk
          return true
        end

        remaining = cap - buffer.bytesize
        buffer << chunk.byteslice(0, remaining) if remaining.positive?
        false
      end

      def env_limit(name, default)
        value = ENV[name].to_i
        value.positive? ? value : default
      end
    end
  end
end
