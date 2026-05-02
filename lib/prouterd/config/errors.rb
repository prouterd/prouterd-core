module Prouterd
  module Config
    class ConfigError < StandardError
      attr_reader :line, :column

      def initialize(message, line: nil, column: nil)
        @line = line
        @column = column
        super(format_message(message))
      end

      private

      def format_message(message)
        prefix = if @line && @column
                   "line #{@line}, col #{@column}: "
                 elsif @line
                   "line #{@line}: "
                 else
                   ""
                 end
        "#{prefix}#{message}"
      end
    end

    class LexError < ConfigError; end
    class ParseError < ConfigError; end
    class ValidationError < ConfigError; end
  end
end
