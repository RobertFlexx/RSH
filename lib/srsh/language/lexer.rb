require_relative '../errors'
require_relative 'token'

module Srsh
  module Language
    class Lexer
      MAX_TOKENS = 100_000
      TWO = %w[== != <= >= ++ ** ?? =~ !~ .. && || |>].freeze
      THREE = %w[..< === !==].freeze

      def initialize(source, line: 1)
        @s = source.to_s
        @i = 0
        @line = line
        @column = 1
        @tokens = 0
      end

      def next_token
        skip_space
        return token(:eof, nil) if eof?
        raise ParseError.new('expression has too many tokens', line: @line, column: @column) if (@tokens += 1) > MAX_TOKENS

        c = peek
        return read_number if digit?(c)
        return read_string if c == '"' || c == "'"
        return read_raw if c == '[' && peek(1) == '['
        return read_dollar if c == '$'
        return read_percent_map if c == '%' && peek(1) == '['
        return read_ident if ident_start?(c)

        start = @column
        three = @s[@i, 3]
        if THREE.include?(three)
          advance(3)
          return Token.new(:op, three, @line, start)
        end

        two = @s[@i, 2]
        case two
        when '::'
          advance(2)
          return Token.new(:lambda, two, @line, start)
        when '=>'
          advance(2)
          return Token.new(:fat_arrow, two, @line, start)
        when '?.'
          advance(2)
          return Token.new(:safe_dot, two, @line, start)
        when '?['
          advance(2)
          return Token.new(:safe_lbracket, two, @line, start)
        end

        if TWO.include?(two)
          advance(2)
          return Token.new(:op, two, @line, start)
        end

        type = case c
               when '(' then :lparen
               when ')' then :rparen
               when '[' then :lbracket
               when ']' then :rbracket
               when ',' then :comma
               when ':' then :colon
               when '.' then :dot
               else :op
               end
        advance
        Token.new(type, c, @line, start)
      end

      private

      def token(type, value, line = @line, col = @column) = Token.new(type, value, line, col)
      def eof? = @i >= @s.length
      def peek(offset = 0) = @s[@i + offset]
      def digit?(c) = c && c >= '0' && c <= '9'
      def ident_start?(c) = c && (c == '_' || c.match?(/[A-Za-z]/))
      def ident_char?(c) = c && (c == '_' || c.match?(/[A-Za-z0-9]/))

      def advance(n = 1)
        n.times do
          break if eof?
          @i += 1
          @column += 1
        end
      end

      def skip_space
        advance while (c = peek) && (c == ' ' || c == "\t" || c == "\r")
      end

      def read_number
        line, col, start = @line, @column, @i
        if peek == '0' && %w[x X b B o O].include?(peek(1))
          base_mark = peek(1).downcase
          advance(2)
          digit_re = { 'x' => /[0-9A-Fa-f]/, 'b' => /[01]/, 'o' => /[0-7]/ }.fetch(base_mark)
          saw_digit = false
          while (c = peek) && (c == '_' || c.match?(digit_re))
            saw_digit ||= c != '_'
            advance
          end
          raise ParseError.new('bad base-prefixed number', line: line, column: col) unless saw_digit
          if (c = peek) && c.match?(/[A-Za-z0-9_]/)
            raise ParseError.new('invalid digit in number', line: line, column: col)
          end
        else
          advance while (c = peek) && (digit?(c) || c == '_')
          if peek == '.' && digit?(peek(1))
            advance
            advance while (c = peek) && (digit?(c) || c == '_')
          end
          if %w[e E].include?(peek)
            advance
            advance if %w[+ -].include?(peek)
            raise ParseError.new('bad exponent', line: line, column: col) unless digit?(peek)
            advance while (c = peek) && (digit?(c) || c == '_')
          end
        end
        raw = @s[start...@i]
        if raw.match?(/(?:\A_|_\z|__|_[.eE+\-]|[.eE+\-]_|[xXbBoO]_)/)
          raise ParseError.new('bad underscore placement in number', line: line, column: col)
        end
        Token.new(:number, raw, line, col)
      end

      def read_string
        quote = peek
        line, col = @line, @column
        advance
        text = +''
        segments = []
        closed = false

        until eof?
          c = peek

          if c == quote
            advance
            closed = true
            break
          end

          if c == '\\'
            advance
            raise IncompleteInput.new('unterminated escape', line: line, column: col) if eof?
            e = peek
            advance
            text << case e
                    when 'n' then "\n"
                    when 'r' then "\r"
                    when 't' then "\t"
                    when '0' then "\0"
                    when '\\' then '\\'
                    when '"' then '"'
                    when "'" then "'"
                    when '#' then '#'
                    else e
                    end
            next
          end

          if quote == '"' && c == '#' && peek(1) == '{'
            segments << [:text, text] unless text.empty?
            text = +''
            segments << [:expr, read_interpolation(line, col)]
            next
          end

          text << c
          advance
        end

        raise IncompleteInput.new('unterminated string', line: line, column: col) unless closed
        if segments.empty?
          Token.new(:string, text, line, col)
        else
          segments << [:text, text] unless text.empty?
          Token.new(:template, segments, line, col)
        end
      end

      def read_interpolation(line, col)
        # cursor is on '#{' here
        advance(2)
        start = @i
        depth = 1
        quote = nil
        escaped = false

        until eof?
          c = peek
          if escaped
            escaped = false
          elsif quote
            if c == '\\'
              escaped = true
            elsif c == quote
              quote = nil
            end
          elsif c == '"' || c == "'"
            quote = c
          elsif c == '{'
            depth += 1
          elsif c == '}'
            depth -= 1
            if depth.zero?
              out = @s[start...@i]
              advance
              raise ParseError.new('empty string interpolation', line: line, column: col) if out.strip.empty?
              return out
            end
          end
          advance
        end

        raise IncompleteInput.new('unterminated string interpolation', line: line, column: col)
      end

      def read_raw
        line, col = @line, @column
        advance(2)
        start = @i
        idx = @s.index(']]', @i)
        raise IncompleteInput.new('unterminated raw string', line: line, column: col) unless idx
        out = @s[start...idx]
        advance(idx - @i + 2)
        Token.new(:string, out, line, col)
      end

      def read_dollar
        line, col = @line, @column
        advance

        if peek == '('
          advance
          return Token.new(:capture, read_capture(line, col), line, col)
        end
        if peek == '?'
          advance
          return Token.new(:status, '?', line, col)
        end
        if digit?(peek)
          start = @i
          advance while digit?(peek)
          return Token.new(:positional, @s[start...@i].to_i, line, col)
        end
        raise ParseError.new('expected environment variable after $', line: line, column: col) unless ident_start?(peek)
        start = @i
        advance while ident_char?(peek)
        Token.new(:env, @s[start...@i], line, col)
      end

      def read_capture(line, col)
        start = @i
        depth = 1
        single = false
        double = false
        escaped = false

        until eof?
          c = peek
          if escaped
            escaped = false
          elsif c == '\\' && !single
            escaped = true
          elsif c == "'" && !double
            single = !single
          elsif c == '"' && !single
            double = !double
          elsif !single && !double && c == '('
            depth += 1
          elsif !single && !double && c == ')'
            depth -= 1
            if depth.zero?
              out = @s[start...@i]
              advance
              return out
            end
          end
          advance
        end

        raise IncompleteInput.new('unterminated command capture', line: line, column: col)
      end

      def read_percent_map
        line, col = @line, @column
        advance(2)
        Token.new(:map_open, '%[', line, col)
      end

      def read_ident
        line, col, start = @line, @column, @i
        if defined?(::SrshNative) && @s.ascii_only? && ::SrshNative.respond_to?(:ident_end)
          finish = ::SrshNative.ident_end(@s, @i)
          advance(finish - @i)
        else
          advance while ident_char?(peek)
        end
        value = @s[start...@i]
        type = case value
               when 'yes', 'true' then :true
               when 'no', 'false' then :false
               when 'void', 'nil' then :void
               when 'and', 'or', 'not', 'in' then :op
               else :ident
               end
        Token.new(type, value, line, col)
      end
    end
  end
end
