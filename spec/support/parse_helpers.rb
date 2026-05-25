module Prouterd
  module Specs
    module ParseHelpers
      def parse(prc)
        Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(prc))
      end
    end
  end
end

RSpec.configure do |config|
  config.include Prouterd::Specs::ParseHelpers
end
