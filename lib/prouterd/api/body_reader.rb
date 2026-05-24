# frozen_string_literal: true

module Prouterd
  module API
    class PayloadTooLarge < StandardError
      attr_reader :limit_bytes

      def initialize(limit_bytes)
        @limit_bytes = limit_bytes
        super("request body too large")
      end
    end

    module BodyReader
      CHUNK_SIZE = 64 * 1024

      def read_bounded_body(request)
        cap = request.env["prouterd.max_body_bytes"].to_i
        cap = App::DEFAULT_MAX_BODY_BYTES unless cap.positive?

        body_io = request.body
        return "" unless body_io

        body_io.rewind if body_io.respond_to?(:rewind)
        out = +""
        total = 0
        while (chunk = body_io.read(CHUNK_SIZE))
          total += chunk.bytesize
          raise PayloadTooLarge, cap if total > cap

          out << chunk
        end
        out
      end
    end
  end
end
