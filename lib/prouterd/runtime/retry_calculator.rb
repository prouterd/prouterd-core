module Prouterd
  module Runtime
    # Computes inter-attempt delays for retry policies.
    #
    # `attempts` is the TOTAL number of tries — `attempts 3` means
    # 1 initial + 2 retries. RetryCalculator therefore yields delays
    # only between attempts (length = attempts - 1).
    #
    # Backoff types:
    #   fixed       — constant initial_delay each time
    #   exponential — initial * 2^(attempt-1), capped at max_delay
    #   linear      — initial * (attempt-1), capped at max_delay
    module RetryCalculator
      module_function

      # Returns delay in milliseconds for the gap BEFORE attempt N (1-indexed).
      # delay_ms_before(2) is the wait between attempt 1 and attempt 2.
      def delay_ms_before(policy, attempt)
        return 0 if attempt <= 1

        initial = policy.retry_initial_delay_ms || 0
        max = policy.retry_max_delay_ms

        raw = case policy.retry_backoff
              when "exponential"
                initial * (2**(attempt - 2))
              when "linear"
                initial * (attempt - 1)
              when "fixed", nil
                initial
              else
                initial
              end

        max ? [raw, max].min : raw
      end

      # True iff the policy permits one more attempt after `attempt`.
      def more_attempts?(policy, attempt)
        return false if policy.nil? || policy.retry_attempts.nil?

        attempt < policy.retry_attempts
      end
    end
  end
end
