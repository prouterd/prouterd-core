module Prouterd
  module Config
    # Tokenizes a .prc source string into an array of Line objects.
    #
    # The DSL is line-oriented: each non-blank, non-comment source line yields
    # one Line containing one or more Tokens. Tokens are either bare words or
    # double-quoted strings. Comments start with `!` or `#` at a token boundary
    # and run to end of line. Indentation is cosmetic and ignored.
    class Lexer
      WHITESPACE = [" ", "\t"].freeze
      COMMENT_CHARS = ["!", "#"].freeze

      def self.tokenize(source)
        new(source).tokenize
      end

      def initialize(source)
        @source = source.to_s
      end

      def tokenize
        result = []
        @source.split("\n", -1).each_with_index do |raw_line, idx|
          line_no = idx + 1
          tokens = tokenize_line(raw_line, line_no)
          result << Line.new(line_no, tokens) unless tokens.empty?
        end
        result
      end

      private

      def tokenize_line(content, line_no)
        tokens = []
        pos = 0
        len = content.length

        while pos < len
          ch = content[pos]

          if WHITESPACE.include?(ch)
            pos += 1
            next
          end

          if COMMENT_CHARS.include?(ch)
            break
          end

          if ch == '"'
            token, pos = read_string(content, pos, len, line_no)
            tokens << token
          else
            token, pos = read_word(content, pos, len, line_no)
            tokens << token
          end
        end

        tokens
      end

      def read_string(content, pos, len, line_no)
        start_col = pos + 1
        pos += 1
        value = String.new(encoding: Encoding::UTF_8)

        while pos < len
          ch = content[pos]
          if ch == '"'
            pos += 1
            return [Token.new(:string, value, line_no, start_col), pos]
          elsif ch == "\\" && pos + 1 < len
            next_ch = content[pos + 1]
            value << unescape(next_ch)
            pos += 2
          else
            value << ch
            pos += 1
          end
        end

        raise LexError.new("unterminated string literal", line: line_no, column: start_col)
      end

      def read_word(content, pos, len, line_no)
        start_col = pos + 1
        value = String.new(encoding: Encoding::UTF_8)

        while pos < len
          ch = content[pos]
          break if WHITESPACE.include?(ch) || ch == '"'
          value << ch
          pos += 1
        end

        [Token.new(:word, value, line_no, start_col), pos]
      end

      def unescape(ch)
        case ch
        when "n" then "\n"
        when "t" then "\t"
        when "r" then "\r"
        when "\\" then "\\"
        when '"' then '"'
        else ch
        end
      end
    end
  end
end
