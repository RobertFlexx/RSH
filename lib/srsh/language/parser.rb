require_relative 'lexer'

module Srsh
  module Language
    class ExprParser
      MAX_NESTING = 256
      MAX_BYTES = 1024 * 1024
      PRECEDENCE = {
        '??' => 1,
        'or' => 2, '||' => 2,
        'and' => 3, '&&' => 3,
        '==' => 4, '!=' => 4, '===' => 4, '!==' => 4, '=~' => 4, '!~' => 4, 'in' => 4,
        '<' => 5, '<=' => 5, '>' => 5, '>=' => 5,
        '|>' => 6,
        '..' => 7, '..<' => 7,
        '++' => 8, '+' => 8, '-' => 8,
        '*' => 9, '/' => 9, '%' => 9,
        '**' => 10
      }.freeze

      def initialize(source, line: 1)
        source = source.to_s
        raise ParseError.new('expression too large', line: line, column: 1) if source.bytesize > MAX_BYTES
        @lexer = Lexer.new(source, line: line)
        @token = @lexer.next_token
        @depth = 0
      end

      def parse
        ast = expression(0)
        error("unexpected #{@token.value.inspect}") unless @token.type == :eof
        ast
      end

      private

      def error(message, token = @token)
        klass = token.type == :eof ? IncompleteInput : ParseError
        raise klass.new(message, line: token.line, column: token.column)
      end

      def advance
        old = @token
        @token = @lexer.next_token
        old
      end

      def expect(type)
        error("expected #{type}, got #{@token.type}") unless @token.type == type
        advance
      end

      def lbp(token)
        token.type == :op ? PRECEDENCE.fetch(token.value, 0) : 0
      end

      def expression(rbp)
        @depth += 1
        error('expression nesting too deep') if @depth > MAX_NESTING
        t = advance
        left = nud(t)
        loop do
          if @token.type == :lparen
            left = parse_call(left)
            next
          elsif @token.type == :lbracket
            advance
            index = expression(0)
            expect(:rbracket)
            left = [:index, left, index]
            next
          elsif @token.type == :dot
            advance
            name = expect(:ident)
            left = [:member, left, name.value]
            next
          elsif @token.type == :safe_dot
            advance
            name = expect(:ident)
            left = [:safe_member, left, name.value]
            next
          elsif @token.type == :safe_lbracket
            advance
            index = expression(0)
            expect(:rbracket)
            left = [:safe_index, left, index]
            next
          end

          power = lbp(@token)
          break if power <= rbp
          op = advance.value
          right_power = op == '**' ? power - 1 : power
          left = [:binary, op, left, expression(right_power)]
        end
        left
      ensure
        @depth -= 1 if @depth.positive?
      end

      def nud(t)
        case t.type
        when :number
          raw = t.value.delete('_')
          value = if raw.match?(/\A0[xX]/) then raw.to_i(16)
                  elsif raw.match?(/\A0[bB]/) then raw.to_i(2)
                  elsif raw.match?(/\A0[oO]/) then raw.to_i(8)
                  elsif raw.include?('.') || raw.match?(/[eE]/) then raw.to_f
                  else raw.to_i
                  end
          [:literal, value]
        when :string then [:literal, t.value]
        when :template
          [:template, t.value.map { |kind, value| kind == :text ? [:text, value] : [:expr, self.class.new(value, line: t.line).parse] }]
        when :true then [:literal, true]
        when :false then [:literal, false]
        when :void then [:literal, nil]
        when :ident then [:local, t.value]
        when :env then [:env, t.value]
        when :positional then [:positional, t.value]
        when :status then [:status]
        when :capture then [:capture, t.value]
        when :lambda then parse_lambda(t)
        when :lparen
          value = expression(0)
          expect(:rparen)
          value
        when :lbracket
          parse_list
        when :map_open
          parse_map
        when :op
          if t.value == '&'
            [:spawn, expression(11)]
          elsif %w[- + not !].include?(t.value)
            [:unary, t.value, expression(11)]
          else
            error("unexpected operator #{t.value.inspect}", t)
          end
        else
          error("unexpected token #{t.type}", t)
        end
      end


      def parse_lambda(token)
        params = []
        if @token.type == :fat_arrow
          # zero-argument hot lambda: :: => expr
        elsif @token.type == :lparen
          advance
          unless @token.type == :rparen
            loop do
              rest = false
              if @token.type == :op && @token.value == '*'
                advance
                rest = true
              end
              name = expect(:ident)
              params << (rest ? "*#{name.value}" : name.value)
              if rest && @token.type != :rparen
                error('rest lambda parameter must be last')
              end
              break if @token.type == :rparen
              expect(:comma)
            end
          end
          expect(:rparen)
        else
          params << expect(:ident).value
        end
        error('expected => after lambda parameters', @token) unless @token.type == :fat_arrow
        advance
        [:lambda, params, expression(0)]
      end

      def parse_list
        items = []
        unless @token.type == :rbracket
          loop do
            items << expression(0)
            break if @token.type == :rbracket
            expect(:comma)
          end
        end
        expect(:rbracket)
        [:list, items]
      end

      def parse_map
        pairs = []
        unless @token.type == :rbracket
          loop do
            key = if @token.type == :ident
                    [:literal, advance.value]
                  else
                    expression(0)
                  end
            expect(:colon)
            pairs << [key, expression(0)]
            break if @token.type == :rbracket
            expect(:comma)
          end
        end
        expect(:rbracket)
        [:map, pairs]
      end

      def parse_call(callee)
        advance
        args = []
        unless @token.type == :rparen
          loop do
            args << expression(0)
            break if @token.type == :rparen
            expect(:comma)
          end
        end
        expect(:rparen)
        [:call, callee, args]
      end
    end

    Command = Data.define(:line, :number)
    Assign = Data.define(:target, :op, :expr, :number)
    DestructureNode = Data.define(:names, :expr, :number)
    Emit = Data.define(:expr, :number)
    ExprNode = Data.define(:expr, :number)
    IfNode = Data.define(:cond, :yes, :no, :number)
    LoopNode = Data.define(:expr, :name, :body, :number)
    WhileNode = Data.define(:cond, :body, :number)
    FunctionNode = Data.define(:name, :params, :body, :number)
    TaskFunctionNode = Data.define(:name, :params, :body, :number)
    ReturnNode = Data.define(:expr, :number)
    BreakNode = Data.define(:number)
    NextNode = Data.define(:number)
    MatchNode = Data.define(:expr, :arms, :number)
    MatchArm = Data.define(:pattern, :body, :number)
    CodeNode = Data.define(:name, :source, :body, :number)
    TryNode = Data.define(:body, :error_name, :catch_body, :finally_body, :number)
    SpaceNode = Data.define(:name, :body, :number)
    SlotNode = Data.define(:name, :expr, :number)
    ProtoNode = Data.define(:name, :params, :traits, :body, :number)
    TraitNode = Data.define(:name, :body, :number)
    BridgeSymbol = Data.define(:name, :params, :result, :number)
    BridgeNode = Data.define(:name, :library, :symbols, :number)
    UseNode = Data.define(:path, :name, :number)
    DeferNode = Data.define(:body, :number)

    class ProgramParser
      MAX_LINES = 100_000
      MAX_NESTING = 256

      def initialize(text, line_offset: 0, nesting: 0)
        raise ParseError, 'script too large' if text.bytesize > 4 * 1024 * 1024
        @lines = text.lines(chomp: true)
        @line_offset = line_offset
        @nesting = nesting
        raise ParseError, 'script has too many lines' if @lines.length > MAX_LINES
        raise ParseError, 'script nesting too deep' if @nesting > MAX_NESTING
      end

      def parse
        nodes, index, stop = parse_nodes(0, [], @nesting)
        raise ParseError.new("unexpected #{stop}", line: @line_offset + index + 1) if stop
        validate_nodes!(nodes)
        nodes
      end

      private

      def clean(line)
        single = false
        double = false
        raw = false
        escaped = false
        out = +''
        i = 0

        while i < line.length
          c = line[i]
          n = line[i + 1]
          if escaped
            out << c
            escaped = false
          elsif !single && !raw && c == '\\'
            out << c
            escaped = true
          elsif !single && !double && c == '[' && n == '['
            raw = true
            out << '[['
            i += 1
          elsif raw && c == ']' && n == ']'
            raw = false
            out << ']]'
            i += 1
          elsif !double && !raw && c == "'"
            single = !single
            out << c
          elsif !single && !raw && c == '"'
            double = !double
            out << c
          elsif c == '#' && !single && !double && !raw
            break
          else
            out << c
          end
          i += 1
        end
        out.rstrip
      end

      def parse_nodes(index, stops, depth)
        raise ParseError.new('script nesting too deep', line: @line_offset + index + 1) if depth > MAX_NESTING
        nodes = []
        while index < @lines.length
          number = @line_offset + index + 1
          line = clean(@lines[index]).strip
          index += 1

          # Value pipelines are allowed to flow vertically. A continuation line
          # beginning with |> is unambiguously RSH expression syntax (Unix uses
          # bare |), so this buys readability without indentation semantics.
          while !line.empty? && index < @lines.length
            continuation = clean(@lines[index]).strip
            break unless continuation.start_with?('|>')
            line << ' ' << continuation
            index += 1
          end

          next if line.empty? || (number == 1 && line.start_with?('#!'))
          return [nodes, index - 1, line] if stops.include?(line)

          case line
          # Readable forms. These intentionally lower to the same nodes as the
          # sigil forms below; maintained scripts and hot scripts are one language.
          when /\Ause\s+(.+?)(?:\s+as\s+([A-Za-z_][A-Za-z0-9_]*))?\s*\z/
            path_expr = Regexp.last_match(1).strip
            alias_name = Regexp.last_match(2)
            nodes << UseNode.new(path_expr, alias_name, number)
          when 'defer'
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed defer block', line: number) unless stop == 'end'
            nodes << DeferNode.new(body, number)
            index = idx + 1
          when /\Adefer\s+(.+)\z/
            nodes << DeferNode.new(parse_inline_statement(Regexp.last_match(1), number, depth), number)
          when 'try'
            node, index = parse_try_block(index, number, depth)
            nodes << node
          when /\Aif\s+(.+?)\s*=>\s*(.+)\z/
            nodes << IfNode.new(Regexp.last_match(1).strip,
                                parse_inline_statement(Regexp.last_match(2), number, depth), [], number)
          when /\Aif\s+(.+)\z/
            yes, idx, stop = parse_nodes(index, ['else', 'end'], depth + 1)
            no = []
            if stop == 'else'
              no, idx2, stop2 = parse_nodes(idx + 1, ['end'], depth + 1)
              raise IncompleteInput.new('unclosed if block', line: number) unless stop2 == 'end'
              index = idx2 + 1
            elsif stop == 'end'
              index = idx + 1
            else
              raise IncompleteInput.new('unclosed if block', line: number)
            end
            nodes << IfNode.new(Regexp.last_match(1).strip, yes, no, number)
          when /\Awhile\s+(.+?)\s*=>\s*(.+)\z/
            nodes << WhileNode.new(Regexp.last_match(1).strip,
                                   parse_inline_statement(Regexp.last_match(2), number, depth), number)
          when /\Awhile\s+(.+)\z/
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed while block', line: number) unless stop == 'end'
            nodes << WhileNode.new(Regexp.last_match(1).strip, body, number)
            index = idx + 1
          when /\Aeach\s+(.+?)\s*->\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*=>\s*(.+)\z/
            nodes << LoopNode.new(Regexp.last_match(1).strip, parse_loop_names(Regexp.last_match(2)),
                                  parse_inline_statement(Regexp.last_match(3), number, depth), number)
          when /\Aeach\s+(.+?)\s*->\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\z/
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed each block', line: number) unless stop == 'end'
            nodes << LoopNode.new(Regexp.last_match(1).strip, parse_loop_names(Regexp.last_match(2)), body, number)
            index = idx + 1
          when /\Atimes\s+(.+)\z/
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed times block', line: number) unless stop == 'end'
            nodes << LoopNode.new(Regexp.last_match(1).strip, 'it', body, number)
            index = idx + 1
          when /\Abridge\s+([A-Za-z_][A-Za-z0-9_]*)\s+from\s+(.+)\z/
            name = Regexp.last_match(1)
            library = Regexp.last_match(2).strip
            symbols, index = parse_bridge_block(index, number, depth)
            nodes << BridgeNode.new(name, library, symbols.freeze, number)
          when /\Aspace\s+([A-Za-z_][A-Za-z0-9_]*)\s*\z/
            name = Regexp.last_match(1)
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed space block', line: number) unless stop == 'end'
            allowed = [Assign, DestructureNode, FunctionNode, TaskFunctionNode, ProtoNode, TraitNode, CodeNode, SpaceNode, BridgeNode, UseNode]
            unless body.all? { |node| allowed.any? { |klass| node.is_a?(klass) } }
              raise ParseError.new('space bodies may contain bindings and declarations only', line: number)
            end
            nodes << SpaceNode.new(name, body, number)
            index = idx + 1
          when /\Aproto\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\((.*?)\))?\s*(?:with\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*))?\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            traits = Regexp.last_match(3).to_s.split(',').map(&:strip).reject(&:empty?).freeze
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed proto block', line: number) unless stop == 'end'
            unless body.all? { |node| node.is_a?(SlotNode) || node.is_a?(FunctionNode) || node.is_a?(TaskFunctionNode) }
              raise ParseError.new('proto bodies may contain only slot, fn, and task declarations', line: number)
            end
            ensure_unique_declarations!(body, number, 'prototype')
            duplicate_trait = traits.group_by(&:itself).find { |_trait, names| names.length > 1 }&.first
            raise ParseError.new("duplicate trait #{duplicate_trait.inspect}", line: number) if duplicate_trait
            nodes << ProtoNode.new(name, params, traits, body, number)
            index = idx + 1
          when /\Atrait\s+([A-Za-z_][A-Za-z0-9_]*)\s*\z/
            name = Regexp.last_match(1)
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed trait block', line: number) unless stop == 'end'
            unless body.all? { |node| node.is_a?(FunctionNode) || node.is_a?(TaskFunctionNode) }
              raise ParseError.new('trait bodies may contain only fn and task declarations', line: number)
            end
            ensure_unique_declarations!(body, number, 'trait')
            nodes << TraitNode.new(name, body, number)
            index = idx + 1
          when /\Acode\s+([A-Za-z_][A-Za-z0-9_]*)\z/
            name = Regexp.last_match(1)
            body_start = index
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed code block', line: number) unless stop == 'end'
            source = @lines[body_start...idx].join("\n")
            nodes << CodeNode.new(name, source, body, number)
            index = idx + 1
          when /\Atask\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*=>\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            expr, index = read_continued_expression(index, number)
            nodes << TaskFunctionNode.new(name, params, [ReturnNode.new(expr, number)], number)
          when /\Atask\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*=>\s*(.+)\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            nodes << TaskFunctionNode.new(name, params, [ReturnNode.new(Regexp.last_match(3).strip, number)], number)
          when /\Atask\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed task block', line: number) unless stop == 'end'
            nodes << TaskFunctionNode.new(name, params, body, number)
            index = idx + 1
          when /\Afn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*=>\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            expr, index = read_continued_expression(index, number)
            nodes << FunctionNode.new(name, params, [ReturnNode.new(expr, number)], number)
          when /\Afn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*=>\s*(.+)\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            nodes << FunctionNode.new(name, params, [ReturnNode.new(Regexp.last_match(3).strip, number)], number)
          when /\Afn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed fn block', line: number) unless stop == 'end'
            nodes << FunctionNode.new(name, params, body, number)
            index = idx + 1
          when /\Afn\s+([A-Za-z_][A-Za-z0-9_]*)\s*(.*)\z/
            name = Regexp.last_match(1)
            args = Regexp.last_match(2).to_s.split(/\s+/).reject(&:empty?).map { |arg| [arg, nil] }
            body, idx, stop = parse_nodes(index, ['end'], depth + 1)
            raise IncompleteInput.new('unclosed fn block', line: number) unless stop == 'end'
            nodes << FunctionNode.new(name, args, body, number)
            index = idx + 1
          when /\Amatch\s+(.+)\z/
            arms, index = parse_match_block(index, number, Regexp.last_match(1).strip, 'end', depth)
            nodes << MatchNode.new(Regexp.last_match(1).strip, arms, number)

          # Hot forms: tiny, visually distinct and deliberately shell-safe.
          when /\A\?\s+(.+?)\s*=>\s*(.+)\z/
            nodes << IfNode.new(Regexp.last_match(1).strip,
                                parse_inline_statement(Regexp.last_match(2), number, depth), [], number)
          when /\A\?\s+(.+)\z/
            yes, idx, stop = parse_nodes(index, [':?', '.?'], depth + 1)
            no = []
            if stop == ':?'
              no, idx2, stop2 = parse_nodes(idx + 1, ['.?'], depth + 1)
              raise IncompleteInput.new('unclosed ? block', line: number) unless stop2 == '.?'
              index = idx2 + 1
            elsif stop == '.?'
              index = idx + 1
            else
              raise IncompleteInput.new('unclosed ? block', line: number)
            end
            nodes << IfNode.new(Regexp.last_match(1).strip, yes, no, number)
          when /\A@\?\s+(.+?)\s*=>\s*(.+)\z/
            nodes << WhileNode.new(Regexp.last_match(1).strip,
                                   parse_inline_statement(Regexp.last_match(2), number, depth), number)
          when /\A@\?\s+(.+)\z/
            body, idx, stop = parse_nodes(index, ['.@'], depth + 1)
            raise IncompleteInput.new('unclosed @? block', line: number) unless stop == '.@'
            nodes << WhileNode.new(Regexp.last_match(1).strip, body, number)
            index = idx + 1
          when /\A@\s+(.+?)\s*->\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*=>\s*(.+)\z/
            nodes << LoopNode.new(Regexp.last_match(1).strip, parse_loop_names(Regexp.last_match(2)),
                                  parse_inline_statement(Regexp.last_match(3), number, depth), number)
          when /\A@\s+(.+?)\s*->\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\z/
            body, idx, stop = parse_nodes(index, ['.@'], depth + 1)
            raise IncompleteInput.new('unclosed @ block', line: number) unless stop == '.@'
            nodes << LoopNode.new(Regexp.last_match(1).strip, parse_loop_names(Regexp.last_match(2)), body, number)
            index = idx + 1
          when /\A::\s*([A-Za-z_][A-Za-z0-9_]*)\s*\((.*)\)\s*=>\s*(.+)\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            nodes << FunctionNode.new(name, params, [ReturnNode.new(Regexp.last_match(3).strip, number)], number)
          when /\A::\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\((.*)\))?\s*\z/
            name = Regexp.last_match(1)
            params = parse_params(Regexp.last_match(2).to_s, number)
            body, idx, stop = parse_nodes(index, ['.::'], depth + 1)
            raise IncompleteInput.new('unclosed :: block', line: number) unless stop == '.::'
            nodes << FunctionNode.new(name, params, body, number)
            index = idx + 1
          when /\A\?\?\s+(.+)\z/
            match_expr = Regexp.last_match(1).strip
            arms, index = parse_match_block(index, number, match_expr, '.??', depth)
            nodes << MatchNode.new(match_expr, arms, number)

          when 'break', '^!'
            nodes << BreakNode.new(number)
          when 'continue', '^>'
            nodes << NextNode.new(number)
          when /\Areturn(?:\s+(.*))?\z/
            expr = Regexp.last_match(1).to_s.strip
            expr, index = complete_expression(expr, index, number) unless expr.empty?
            nodes << ReturnNode.new(expr, number)
          when /\A\^\s*(.*)\z/
            nodes << ReturnNode.new(Regexp.last_match(1).strip, number)
          when /\A=\s*(.+)\z/
            expr, index = complete_expression(Regexp.last_match(1), index, number)
            nodes << Emit.new(expr, number)
          when /\Aemit\s+(.+)\z/
            expr, index = complete_expression(Regexp.last_match(1), index, number)
            nodes << Emit.new(expr, number)
          when /\Aslot\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+)\z/
            slot_name, rhs = Regexp.last_match(1), Regexp.last_match(2)
            rhs, index = complete_expression(rhs, index, number)
            nodes << SlotNode.new(slot_name, rhs, number)
          when /\A((?:\*?[A-Za-z_][A-Za-z0-9_]*\s*,\s*)+\*?[A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+)\z/
            names = Regexp.last_match(1).split(',').map(&:strip)
            rest = names.each_index.select { |i| names[i].start_with?('*') }
            raise ParseError.new('destructuring allows one rest name, and it must be last', line: number) if rest.length > 1 || (rest.any? && rest[0] != names.length - 1)
            rhs, index = complete_expression(Regexp.last_match(2), index, number)
            nodes << DestructureNode.new(names.freeze, rhs, number)
          when /\A((?:[A-Za-z_][A-Za-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*(:=|\+=|-=|\*=|\/=|%=|\+\+=)\s*(.+)\z/
            target, op, rhs = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
            rhs, index = complete_expression(rhs, index, number)
            nodes << Assign.new(target, op, rhs, number)
          when /\A(\$?[A-Za-z_][A-Za-z0-9_]*)\s*(:=|\+=|-=|\*=|\/=|%=|\+\+=)\s*(.+)\z/
            target, op, rhs = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
            rhs, index = complete_expression(rhs, index, number)
            nodes << Assign.new(target, op, rhs, number)
          when /\A([A-Za-z_][A-Za-z0-9_]*)\s+=\s+(.+)\z/
            name, rhs = Regexp.last_match(1), Regexp.last_match(2)
            rhs, index = complete_expression(rhs, index, number)
            nodes << Assign.new("$#{name}", ':=', rhs, number)
          when /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*\(.*\)\s*\z/
            nodes << ExprNode.new(line, number)
          when /\|>/
            # A bare value pipeline is an expression statement. Keeping this
            # explicit avoids stealing ordinary shell commands such as `ls -la`.
            ExprParser.new(line, line: number).parse
            nodes << ExprNode.new(line, number)
          else
            if line.start_with?('.?', '.@', '.::', '.??', ':?', '| ') || %w[else end].include?(line)
              return [nodes, index - 1, line]
            end
            nodes << Command.new(line, number)
          end
        end
        [nodes, index, nil]
      end

      def parse_loop_names(text)
        names = text.to_s.split(',').map(&:strip)
        return names.first if names.length == 1
        raise ParseError, 'loop destructuring supports at most 8 names' if names.length > 8
        names.freeze
      end

      def parse_inline_statement(text, number, depth)
        parsed = self.class.new(text.to_s + "\n", line_offset: number - 1, nesting: depth + 1).parse
        raise ParseError.new('inline form requires one statement', line: number) unless parsed.length == 1
        parsed
      end

      def parse_try_block(index, number, depth)
        body_start = index
        catch_start = nil
        catch_end = nil
        catch_name = nil
        finally_start = nil
        finally_end = nil
        body_end = nil
        nested = 0
        phase = :body
        closed = false

        while index < @lines.length
          candidate = clean(@lines[index]).strip

          if nested.zero?
            if candidate =~ /\Acatch(?:\s+([A-Za-z_][A-Za-z0-9_]*))?\s*\z/
              raise ParseError.new('try block has more than one catch', line: @line_offset + index + 1) if catch_start
              raise ParseError.new('catch must appear before finally', line: @line_offset + index + 1) if phase == :finally
              body_end ||= index
              catch_name = Regexp.last_match(1) || 'error'
              catch_start = index + 1
              phase = :catch
              index += 1
              next
            elsif candidate == 'finally'
              raise ParseError.new('try block has more than one finally', line: @line_offset + index + 1) if finally_start
              if phase == :body
                body_end ||= index
              elsif phase == :catch
                catch_end = index
              end
              finally_start = index + 1
              phase = :finally
              index += 1
              next
            elsif candidate == 'end'
              if phase == :body
                body_end ||= index
              elsif phase == :catch
                catch_end ||= index
              else
                finally_end = index
              end
              closed = true
              index += 1
              break
            end
          end

          if block_opener?(candidate)
            nested += 1
          elsif block_closer?(candidate) && nested.positive?
            nested -= 1
          end
          index += 1
        end

        raise IncompleteInput.new('unclosed try block', line: number) unless closed
        raise ParseError.new('try needs catch and/or finally', line: number) unless catch_start || finally_start

        body_text = @lines[body_start...(body_end || body_start)].join("\n")
        body = self.class.new(body_text, line_offset: @line_offset + body_start, nesting: depth + 1).parse

        catch_body = []
        if catch_start
          last = catch_end || (finally_start ? finally_start - 1 : index - 1)
          catch_text = @lines[catch_start...last].join("\n")
          catch_body = self.class.new(catch_text, line_offset: @line_offset + catch_start, nesting: depth + 1).parse
        end

        finally_body = []
        if finally_start
          last = finally_end || index - 1
          finally_text = @lines[finally_start...last].join("\n")
          finally_body = self.class.new(finally_text, line_offset: @line_offset + finally_start, nesting: depth + 1).parse
        end

        [TryNode.new(body, catch_name, catch_body, finally_body, number), index]
      end

      def read_continued_expression(index, number)
        while index < @lines.length && clean(@lines[index]).strip.empty?
          index += 1
        end
        raise IncompleteInput.new('expected expression after =>', line: number) if index >= @lines.length

        expression = clean(@lines[index]).strip
        index += 1
        complete_expression(expression, index, number)
      end

      # Expression statements can span physical lines whenever the parser says
      # it reached EOF too early. This is what makes pasted list/map/call literals
      # work at the REPL without an indentation grammar or backslash ceremony.
      def complete_expression(expression, index, number)
        text = expression.to_s.strip
        loop do
          begin
            ExprParser.new(text, line: number).parse
            return [text, index]
          rescue IncompleteInput
            raise if index >= @lines.length
            continuation = clean(@lines[index]).strip
            index += 1
            next if continuation.empty?
            text << " " << continuation
          end
        end
      end

      def parse_bridge_block(index, number, depth)
        raise ParseError.new('script nesting too deep', line: number) if depth > MAX_NESTING
        symbols = []
        names = {}
        closed = false
        while index < @lines.length
          line_no = @line_offset + index + 1
          line = clean(@lines[index]).strip
          index += 1
          next if line.empty?
          if line == 'end'
            closed = true
            break
          end
          match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)\s*->\s*([A-Za-z_][A-Za-z0-9_]*)\s*\z/)
          unless match
            raise ParseError.new('bridge entries use name(type, ...) -> type', line: line_no)
          end
          name = match[1]
          raise ParseError.new("duplicate bridge symbol #{name.inspect}", line: line_no) if names[name]
          names[name] = true
          params = match[2].strip.empty? ? [] : split_top_level(match[2], ',').map(&:strip)
          result = match[3]
          symbols << BridgeSymbol.new(name, params.freeze, result, line_no)
        end
        raise IncompleteInput.new('unclosed bridge block', line: number) unless closed
        [symbols, index]
      end

      def parse_match_block(index, number, match_expr, close_token, depth)
        arms = []
        closed = false

        while index < @lines.length
          while index < @lines.length && clean(@lines[index]).strip.empty?
            index += 1
          end
          break if index >= @lines.length

          arm_line = clean(@lines[index]).strip
          arm_no = @line_offset + index + 1
          if arm_line == close_token
            index += 1
            closed = true
            break
          end

          if arm_line =~ /\A\|(?!>)\s*(.+?)\s*=>\s*(.+)\z/
            pattern = Regexp.last_match(1).strip
            body = parse_inline_statement(Regexp.last_match(2), arm_no, depth + 1)
            arms << MatchArm.new(pattern, body, arm_no)
            index += 1
            next
          end

          # A match arm can put its body inline with =>, or put the body on
          # following lines with either => or ->.  Treating bare => as an
          # incomplete arm was a nasty paste-time footgun: the readable form
          # looked valid, but only the old arrow spelling accepted a block.
          unless arm_line =~ /\A\|(?!>)\s*(.+?)\s*(?:->|=>)\s*\z/
            raise ParseError.new('expected | pattern => statement or | pattern =>/-> block', line: arm_no)
          end
          pattern = Regexp.last_match(1).strip
          index += 1

          body_start = index
          nested = 0
          while index < @lines.length
            candidate = clean(@lines[index]).strip
            arm_marker = candidate.match?(/\A\|(?!>)\s*.+?\s*(?:->|=>)/)
            break if nested.zero? && (candidate == close_token || arm_marker)
            nested += 1 if block_opener?(candidate)
            nested -= 1 if block_closer?(candidate) && nested.positive?
            index += 1
          end

          body_text = @lines[body_start...index].join("\n")
          body = self.class.new(body_text, line_offset: @line_offset + body_start, nesting: depth + 1).parse
          arms << MatchArm.new(pattern, body, arm_no)
        end

        raise ParseError.new('empty match block', line: number) if arms.empty?
        raise IncompleteInput.new("unclosed #{close_token == '.??' ? '??' : 'match'} block", line: number) unless closed
        [arms, index]
      end

      def block_opener?(line)
        return false if line.include?('=>')
        line.match?(/\A(?:try$|defer$|if\s+|while\s+|times\s+|each\s+|code\s+|bridge\s+|space\s+|proto\s+|trait\s+|task\s+|fn\s+|match\s+|\?\s+|@\?\s+|@\s+|::\s*|\?\?\s+)/)
      end

      def block_closer?(line)
        %w[end .? .@ .:: .??].include?(line)
      end

      def ensure_unique_declarations!(nodes, line, owner)
        seen = {}
        nodes.each do |node|
          next unless node.respond_to?(:name)
          key = node.name.to_s
          raise ParseError.new("duplicate #{owner} declaration #{key.inspect}", line: node.number || line) if seen[key]
          seen[key] = true
        end
      end

      def validate_nodes!(nodes)
        nodes.each do |node|
          case node
          when Assign
            validate_expr!(node.expr, node.number)
          when DestructureNode
            validate_expr!(node.expr, node.number)
          when Emit, ExprNode
            validate_expr!(node.expr, node.number)
          when IfNode
            validate_expr!(node.cond, node.number)
            validate_nodes!(node.yes)
            validate_nodes!(node.no)
          when LoopNode
            validate_expr!(node.expr, node.number)
            validate_nodes!(node.body)
          when WhileNode
            validate_expr!(node.cond, node.number)
            validate_nodes!(node.body)
          when FunctionNode, TaskFunctionNode
            node.params.each { |_name, default| validate_expr!(default, node.number) if default && !default.empty? }
            validate_nodes!(node.body)
          when ReturnNode
            validate_expr!(node.expr, node.number) unless node.expr.empty?
          when MatchNode
            validate_expr!(node.expr, node.number)
            node.arms.each do |arm|
              unless arm.pattern == '_'
                pattern_expr = if arm.pattern.start_with?('? ')
                                 arm.pattern[2..].strip
                               elsif arm.pattern.start_with?('when ')
                                 arm.pattern[5..].strip
                               else
                                 arm.pattern
                               end
                validate_expr!(pattern_expr, arm.number)
              end
              validate_nodes!(arm.body)
            end
          when CodeNode
            validate_nodes!(node.body)
          when TryNode
            validate_nodes!(node.body)
            validate_nodes!(node.catch_body)
            validate_nodes!(node.finally_body)
          when SpaceNode
            validate_nodes!(node.body)
          when SlotNode
            validate_expr!(node.expr, node.number)
          when ProtoNode
            node.params.each { |_name, default| validate_expr!(default, node.number) if default && !default.empty? }
            validate_nodes!(node.body)
          when TraitNode
            validate_nodes!(node.body)
          when BridgeNode
            validate_expr!(node.library, node.number)
          when UseNode
            validate_expr!(node.path, node.number)
          when DeferNode
            validate_nodes!(node.body)
          end
        end
      end

      def validate_expr!(expr, line)
        ExprParser.new(expr, line: line).parse
      end

      def parse_params(text, line)
        return [] if text.strip.empty?
        parts = split_top_level(text, ',')
        seen_rest = false
        seen_names = {}
        parts.each_with_index.map do |part, index|
          assignment = find_top_level(part, ':=')
          if assignment
            name = part[0...assignment].strip
            default = part[(assignment + 2)..].strip
            raise ParseError.new('missing default parameter expression', line: line) if default.empty?
          else
            name = part.strip
            default = nil
          end

          rest = name.start_with?('*')
          bare = rest ? name[1..] : name
          unless bare&.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
            raise ParseError.new("bad parameter #{name.inspect}", line: line)
          end
          raise ParseError.new("duplicate parameter #{bare.inspect}", line: line) if seen_names[bare]
          seen_names[bare] = true
          if rest
            raise ParseError.new('rest parameter cannot have a default', line: line) if default
            raise ParseError.new('rest parameter must be last', line: line) unless index == parts.length - 1
            raise ParseError.new('only one rest parameter is allowed', line: line) if seen_rest
            seen_rest = true
            name = "*#{bare}"
          end
          [name, default]
        end
      end

      def split_top_level(text, delimiter)
        parts = []
        start = 0
        depth = 0
        quote = nil
        raw = false
        escaped = false
        i = 0
        while i < text.length
          c = text[i]
          n = text[i + 1]
          if escaped
            escaped = false
          elsif quote
            if c == '\\' && quote == '"'
              escaped = true
            elsif c == quote
              quote = nil
            end
          elsif raw
            if c == ']' && n == ']'
              raw = false
              i += 1
            end
          elsif c == '[' && n == '['
            raw = true
            i += 1
          elsif c == "'" || c == '"'
            quote = c
          elsif c == '(' || c == '['
            depth += 1
          elsif c == ')' || c == ']'
            depth -= 1 if depth.positive?
          elsif c == delimiter && depth.zero?
            parts << text[start...i]
            start = i + 1
          end
          i += 1
        end
        raise IncompleteInput, 'unterminated parameter expression' if quote || raw || depth.positive?
        parts << text[start..]
        parts
      end

      def find_top_level(text, needle)
        depth = 0
        quote = nil
        raw = false
        escaped = false
        i = 0
        while i < text.length - 1
          c = text[i]
          n = text[i + 1]
          if escaped
            escaped = false
          elsif quote
            if c == '\\' && quote == '"'
              escaped = true
            elsif c == quote
              quote = nil
            end
          elsif raw
            if c == ']' && n == ']'
              raw = false
              i += 1
            end
          elsif c == '[' && n == '['
            raw = true
            i += 1
          elsif c == "'" || c == '"'
            quote = c
          elsif c == '(' || c == '['
            depth += 1
          elsif c == ')' || c == ']'
            depth -= 1 if depth.positive?
          elsif depth.zero? && text[i, needle.length] == needle
            return i
          end
          i += 1
        end
        nil
      end
    end
  end
end
