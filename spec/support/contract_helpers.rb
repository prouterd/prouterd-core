module Prouterd
  module Specs
    # Helpers for /v1 contract specs (Phase 36a). Stricter than
    # `match(hash_including(...))` — fails if any unexpected key is
    # present in the response. The /v1 contract is the spec; future
    # changes that drift the shape will fail loud.
    module ContractHelpers
      # Asserts the hash has exactly the given keys (no more, no fewer)
      # and that each value matches the matcher (Class, RSpec matcher,
      # or literal). Use Class for type, custom matchers for nested
      # shape, plain values for equality.
      def expect_keys(hash, expected)
        expect(hash).to be_a(Hash), "expected a Hash, got #{hash.class}"
        actual = hash.keys.sort
        expected_keys = expected.keys.map(&:to_s).sort
        extra = actual - expected_keys
        missing = expected_keys - actual
        raise "extra keys: #{extra.inspect}" unless extra.empty?
        raise "missing keys: #{missing.inspect}" unless missing.empty?

        expected.each do |key, matcher|
          value = hash[key.to_s]
          if matcher.is_a?(Class)
            unless value.is_a?(matcher) || value.nil?
              raise "key #{key.inspect}: expected #{matcher}, got #{value.class} (#{value.inspect})"
            end
          elsif matcher.nil?
            raise "key #{key.inspect}: expected nil, got #{value.inspect}" unless value.nil?
          elsif matcher.respond_to?(:matches?)
            # RSpec custom matcher (a_kind_of, a_hash_including, etc.).
            expect(value).to(matcher)
          else
            # Plain literal — equality.
            expect(value).to(eq(matcher))
          end
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include Prouterd::Specs::ContractHelpers, type: :contract
  # Allow include manually too without a metadata tag.
  config.include Prouterd::Specs::ContractHelpers
end
