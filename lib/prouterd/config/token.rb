# frozen_string_literal: true

module Prouterd
  module Config
    Token = Struct.new(:type, :value, :line, :column) do
      def word?
        type == :word
      end

      def string?
        type == :string
      end

      def to_s
        string? ? value.inspect : value
      end
    end

    Line = Struct.new(:number, :tokens) do
      def head
        tokens.first
      end

      def rest
        tokens[1..] || []
      end
    end
  end
end
