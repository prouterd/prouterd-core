# frozen_string_literal: true

module Prouterd
  module Runner
    # Test-only runner that returns programmed ExecutionResults.
    #
    # Programs a sequence of behaviors keyed by block name OR by FIFO order.
    # The Orchestrator's tests need to drive specific outcomes per block; the
    # stub captures the RunRequest each call so assertions can inspect what
    # the orchestrator passed in.
    class StubRunner
      attr_reader :calls

      def initialize
        @calls = []
        @by_block = {}
        @sequence = []
        @default = ->(req) {
          ExecutionResult.new(
            exit_code: 0,
            stdout: "",
            stderr: "",
            output_json: { "block" => req.block_name, "ok" => true },
            artifacts: [],
            error_type: nil,
            error_message: nil,
            duration_ms: 1,
            started_at: nil,
            finished_at: nil
          )
        }
      end

      # `program(block_name)` — when this block runs, return the given result.
      # Block can be a Proc receiving the RunRequest.
      def program(block_name, &block)
        @by_block[block_name] = block
      end

      # `program_next(&block)` — FIFO programming for block-agnostic sequences.
      def program_next(&block)
        @sequence << block
      end

      # `default(&block)` — fall-through for any unprogrammed block.
      def default(&block)
        @default = block
      end

      def run(request)
        @calls << request
        if (handler = @by_block[request.block_name])
          handler.call(request)
        elsif (handler = @sequence.shift)
          handler.call(request)
        else
          @default.call(request)
        end
      end

      # Convenience helpers for common test scenarios.
      def self.success(output: { "ok" => true }, stdout: "", stderr: "")
        proc do |_req|
          ExecutionResult.new(
            exit_code: 0,
            stdout: stdout, stderr: stderr,
            output_json: output,
            artifacts: [],
            error_type: nil, error_message: nil,
            duration_ms: 1,
            started_at: nil, finished_at: nil
          )
        end
      end

      def self.failure(error_type: "non_zero_exit", error_message: "boom", exit_code: 1, stderr: "")
        proc do |_req|
          ExecutionResult.new(
            exit_code: exit_code,
            stdout: "", stderr: stderr,
            output_json: nil,
            artifacts: [],
            error_type: error_type, error_message: error_message,
            duration_ms: 1,
            started_at: nil, finished_at: nil
          )
        end
      end
    end
  end
end
