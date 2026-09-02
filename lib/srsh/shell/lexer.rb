require_relative '../errors'

module Srsh
  module Shell
    Lexeme = Data.define(:type, :text)

    class Lexer
      OPERATORS = %w[2>> 2> >> && || | & ; > <].freeze
      MAX_INPUT = 1024 * 1024
      MAX_LEXEMES = 100_000

      def self.scan(input)
        new(input).scan
      end

      def initialize(input)
        @s = input.to_s
        raise ParseError, 'command line too large' if @s.bytesize > MAX_INPUT
      end

      def scan
        out = []
        buf = +''
        quote = nil
        escaped = false
        subst_depth = 0
        i = 0

        flush = lambda do
          unless buf.empty?
            raise ParseError, 'command has too many tokens' if out.length >= MAX_LEXEMES
            out << Lexeme.new(:word, buf)
            buf = +''
          end
        end

        while i < @s.length
          c = @s[i]

          if escaped
            buf << c
            escaped = false
            i += 1
            next
          end

          if c == '\\'
            buf << c
            escaped = true
            i += 1
            next
          end

          if quote
            buf << c
            quote = nil if c == quote
            i += 1
            next
          end

          if c == "'" || c == '"'
            quote = c
            buf << c
            i += 1
            next
          end

          if c == '$' && @s[i + 1] == '('
            subst_depth += 1
            buf << '$('
            i += 2
            next
          elsif c == '(' && subst_depth.positive?
            subst_depth += 1
            buf << c
            i += 1
            next
          elsif c == ')' && subst_depth.positive?
            subst_depth -= 1
            buf << c
            i += 1
            next
          end

          if subst_depth.zero? && c.match?(/\s/)
            flush.call
            i += 1
            next
          end

          if subst_depth.zero?
            op = OPERATORS.find { |candidate| @s[i, candidate.length] == candidate }
            if op
              flush.call
              raise ParseError, 'command has too many tokens' if out.length >= MAX_LEXEMES
              out << Lexeme.new(:op, op)
              i += op.length
              next
            end
          end

          buf << c
          i += 1
        end

        raise IncompleteInput, 'trailing backslash' if escaped
        raise IncompleteInput, 'unterminated quote' if quote
        raise IncompleteInput, 'unterminated command substitution' unless subst_depth.zero?
        flush.call
        out
      end
    end
  end
end
