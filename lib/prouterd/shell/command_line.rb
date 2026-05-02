module Prouterd
  module Shell
    # Tokenizes a single line of user input into Tokens, reusing the .prc
    # config Lexer so quoting and escape rules match the file format.
    #
    # Returns nil for blank/comment-only lines, otherwise an array of Tokens.
    module CommandLine
      module_function

      def tokenize(input)
        lines = Config::Lexer.tokenize(input)
        return nil if lines.empty?
        return nil if lines.length == 1 && lines.first.tokens.empty?

        # If the user paste-included multiple lines, only consider the first.
        lines.first.tokens
      end

      # Convenience: token values as strings.
      def words(input)
        tokens = tokenize(input)
        tokens ? tokens.map(&:value) : nil
      end
    end
  end
end
