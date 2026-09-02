require 'shellwords'
require 'stringio'
require_relative '../errors'
require_relative '../language/parser'
require_relative '../language/evaluator'
require_relative 'lexer'
require_relative 'job'
require_relative 'terminal'

module Srsh
  module Shell
    Stage = Data.define(:words, :stdin_path, :stdout_path, :stdout_append, :stderr_path, :stderr_append)
    Pipeline = Data.define(:stages, :background, :source)

    class Executor
      MAX_ALIAS_DEPTH = 32
      MAX_SUBST_DEPTH = 16
      MAX_SUBST_BYTES = 512 * 1024
      MAX_FUNCTION_DEPTH = 128

      attr_reader :evaluator

      def initialize(app)
        @app = app
        @state = app.state
        @evaluator = Language::Evaluator.new(@state, self)
        @command_cache = {}
      end

      def function?(name) = @state.functions.key?(name)
      def prototype?(name) = @state.prototypes.key?(name)

      def prototype_methods(name)
        proto = @state.prototypes[name.to_s]
        proto ? proto[:methods].keys.sort : []
      end

      def object_method?(object, name)
        proto = @state.prototypes[object.proto_name]
        proto && proto[:methods].key?(name.to_s)
      end

      def execute_line(line, capture: false)
        chunks = split_connectors(line)
        status = @state.last_status
        chunks.each do |connector, text|
          run = connector == :seq || (connector == :and && status.zero?) || (connector == :or && !status.zero?)
          next unless run
          status = execute_pipeline(text, capture: capture)
          @state.last_status = status
        end
        status
      rescue ParseError => e
        @app.err.puts @app.theme.paint("srsh: #{e.message}", :error, io: @app.err)
        @state.last_status = 2
      end

      def capture(command)
        key = :"srsh_subst_depth_#{object_id}"
        depth = Thread.current[key].to_i
        raise RuntimeError, 'command substitution nesting too deep' if depth >= MAX_SUBST_DEPTH
        Thread.current[key] = depth + 1
        r, w = IO.pipe
        pid = fork do
          begin
            r.close
            STDOUT.reopen(w)
            @app.out = STDOUT if @app.respond_to?(:out=)
            status = execute_line(command, capture: true)
            STDOUT.flush
            exit!(status.to_i & 0xff)
          rescue Exception => e # child boundary
            STDERR.puts "srsh substitution: #{e.message}"
            exit!(125)
          end
        end
        w.close
        data = +''
        while (chunk = r.read(16 * 1024))
          break if chunk.empty?
          remaining = MAX_SUBST_BYTES - data.bytesize
          break if remaining <= 0
          data << chunk.byteslice(0, remaining)
        end
        r.close
        Process.wait(pid)
        @state.last_status = $?.exitstatus || 1
        data.sub(/\n+\z/, '')
      ensure
        Thread.current[key] = [Thread.current[key].to_i - 1, 0].max if defined?(key)
      end

      def call_function(name, args, call_seed: nil)
        fn = @state.functions[name]
        raise RuntimeError, "unknown function #{name}" unless fn
        seed = (call_seed || {}).merge(captured_seed(fn))
        if fn[:async]
          # Async calls cross to a fresh OS thread. Plain data is copied so
          # lexical capture cannot smuggle accidental shared mutation across.
          async_seed = @evaluator.worker_snapshot(@state.locals_snapshot.merge(seed))
          async_args = @evaluator.worker_snapshot(args)
          return Language::TaskValue.new do
            invoke_rsh_body(name, fn[:params], fn[:body], fn[:line], async_args, async_seed)
          end
        end
        invoke_rsh_body(name, fn[:params], fn[:body], fn[:line], args, seed)
      end

      def instantiate(name, args)
        proto = @state.prototypes[name.to_s]
        raise RuntimeError, "unknown prototype #{name}" unless proto
        object = Language::ObjectValue.new(name)
        with_call_depth('prototype construction') do
          scope = captured_seed(proto).merge('$0' => name.to_s, 'self' => object)
          args.each_with_index { |value, index| scope["$#{index + 1}"] = value }
          @state.push_scope(scope)
          begin
            bind_params(proto[:params], args, proto[:line])
            proto[:slots].each do |slot|
              value = @evaluator.parse_eval(slot.expr, line: slot.number)
              object.set(slot.name, value)
            end
          ensure
            @state.pop_scope
          end
        end
        object
      end

      def call_method(object, name, args)
        proto = @state.prototypes[object.proto_name]
        fn = proto && proto[:methods][name.to_s]
        raise RuntimeError, "#{object.proto_name} has no method .#{name}" unless fn
        seed = captured_seed(fn).merge('self' => object)
        if fn[:async]
          async_seed = @evaluator.worker_snapshot(@state.locals_snapshot.merge(seed))
          async_args = @evaluator.worker_snapshot(args)
          return Language::TaskValue.new do
            invoke_rsh_body("#{object.proto_name}.#{name}", fn[:params], fn[:body], fn[:line], async_args, async_seed)
          end
        end
        invoke_rsh_body("#{object.proto_name}.#{name}", fn[:params], fn[:body], fn[:line], args, seed)
      end

      def captured_seed(definition)
        captured = definition[:captured]
        case captured
        when Language::NamespaceValue then captured.members.dup
        when Hash then captured.dup
        else {}
        end
      end

      def register_function_node(node, name: node.name, captured: nil)
        @state.functions[name] = { params: node.params, body: node.body, line: node.number,
                                   async: node.is_a?(Language::TaskFunctionNode), captured: captured }
      end

      def register_trait_node(node, name: node.name, captured: nil)
        methods = node.body.to_h do |part|
          [part.name, { params: part.params, body: part.body, line: part.number,
                        async: part.is_a?(Language::TaskFunctionNode), captured: captured }]
        end.freeze
        @state.traits[name] = { methods: methods, line: node.number, captured: captured }.freeze
      end

      def register_proto_node(node, name: node.name, captured: nil, trait_prefix: nil)
        slots = node.body.select { |part| part.is_a?(Language::SlotNode) }.freeze
        methods = {}
        node.traits.each do |trait_name|
          qualified = trait_prefix ? "#{trait_prefix}.#{trait_name}" : nil
          trait = (qualified && @state.traits[qualified]) || @state.traits[trait_name]
          raise RuntimeError, "unknown trait #{trait_name} for proto #{name}" unless trait
          methods.merge!(trait[:methods])
        end
        node.body.select { |part| part.is_a?(Language::FunctionNode) || part.is_a?(Language::TaskFunctionNode) }.each do |part|
          methods[part.name] = { params: part.params, body: part.body, line: part.number,
                                 async: part.is_a?(Language::TaskFunctionNode), captured: captured }
        end
        @state.prototypes[name] = { params: node.params.freeze, traits: node.traits, slots: slots,
                                    methods: methods.freeze, line: node.number, captured: captured }.freeze
      end

      def define_space(node)
        key = :"srsh_space_prefix_#{object_id}"
        parent_prefix = Thread.current[key]
        prefix = parent_prefix ? "#{parent_prefix}.#{node.name}" : node.name
        namespace = Language::NamespaceValue.new(prefix)
        module_source = Thread.current[:"srsh_module_source_#{object_id}"]
        namespace.set('$0', module_source) if module_source
        old_prefix = Thread.current[key]
        Thread.current[key] = prefix

        # Predeclare callable members so constants, defaults and sibling functions
        # can refer to definitions that appear later in the source file.
        node.body.each do |part|
          case part
          when Language::FunctionNode, Language::TaskFunctionNode
            qname = "#{prefix}.#{part.name}"
            namespace.set(part.name, Language::FunctionRef.new(qname))
          when Language::ProtoNode
            qname = "#{prefix}.#{part.name}"
            namespace.set(part.name, Language::PrototypeRef.new(qname))
          end
        end

        node.body.grep(Language::TraitNode).each do |part|
          register_trait_node(part, name: "#{prefix}.#{part.name}", captured: namespace)
        end
        node.body.grep(Language::FunctionNode).each do |part|
          register_function_node(part, name: "#{prefix}.#{part.name}", captured: namespace)
        end
        node.body.grep(Language::TaskFunctionNode).each do |part|
          register_function_node(part, name: "#{prefix}.#{part.name}", captured: namespace)
        end
        node.body.grep(Language::ProtoNode).each do |part|
          register_proto_node(part, name: "#{prefix}.#{part.name}", captured: namespace, trait_prefix: prefix)
        end

        @state.push_scope(namespace.members)
        begin
          node.body.each do |part|
            next if part.is_a?(Language::FunctionNode) || part.is_a?(Language::TaskFunctionNode) ||
                    part.is_a?(Language::TraitNode) || part.is_a?(Language::ProtoNode)
            run_nodes([part])
          end
        ensure
          @state.pop_scope
          Thread.current[key] = old_prefix
        end
        @state.local_define(node.name, namespace)
        @state.last_status = 0
        namespace
      end

      def use_module(node)
        requested = @evaluator.parse_eval(node.path, line: node.number).to_s
        caller = @state.local_get('$0').to_s
        base = !caller.empty? && File.file?(caller) ? File.dirname(File.expand_path(caller)) : Dir.pwd
        path = File.expand_path(requested, base)
        raise RuntimeError, "module not found: #{requested}" unless File.file?(path)
        raise RuntimeError, "module too large: #{requested}" if File.size(path) > 4 * 1024 * 1024
        stack_key = :"srsh_module_stack_#{object_id}"
        stack = Thread.current[stack_key] ||= []
        raise RuntimeError, "module cycle: #{(stack + [path]).join(' -> ')}" if stack.include?(path)
        source = File.binread(path, 4 * 1024 * 1024 + 1)
        raise RuntimeError, "module too large: #{requested}" if source.bytesize > 4 * 1024 * 1024
        source.force_encoding(Encoding::UTF_8)
        raise RuntimeError, "module is not valid UTF-8: #{requested}" unless source.valid_encoding?
        body = Language::ProgramParser.new(source).parse
        name = node.name || File.basename(path, File.extname(path)).gsub(/[^A-Za-z0-9_]/, '_')
        raise RuntimeError, "bad module namespace #{name.inspect}" unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        source_key = :"srsh_module_source_#{object_id}"
        old_source = Thread.current[source_key]
        stack << path
        Thread.current[source_key] = path
        begin
          define_space(Language::SpaceNode.new(name, body, node.number))
        ensure
          Thread.current[source_key] = old_source
          stack.pop
        end
      end

      def defer_stack
        Thread.current[:"srsh_defer_stack_#{object_id}"] ||= []
      end

      def register_defer(body)
        raise RuntimeError, 'defer used outside an execution scope' if defer_stack.empty?
        defer_stack.last << body
      end

      def with_defer_scope
        actions = []
        defer_stack << actions
        begin
          yield
        ensure
          # Keep this scope active while cleanups run: a cleanup can itself
          # defer another cleanup, and it should run immediately after it.
          while (body = actions.pop)
            run_nodes(body)
          end
          defer_stack.pop
        end
      end

      def define_bridge(node)
        path = @evaluator.parse_eval(node.library, line: node.number)
        path = path.to_s
        library = Language::NativeLibraryValue.new(node.name, path)
        node.symbols.each do |symbol|
          library.set(symbol.name, Language::NativeFunctionValue.new(library.handle, symbol.name, symbol.params, symbol.result))
        end
        @state.local_define(node.name, library)
        @state.last_status = 0
        library
      end

      def invoke_rsh_body(label, params, body, line, args, seed = {})
        with_call_depth(label) do
          scope = { '$0' => label }.merge(seed)
          args.each_with_index { |value, index| scope["$#{index + 1}"] = value }
          @state.push_scope(scope)
          begin
            bind_params(params, args, line)
            with_defer_scope { run_nodes(body) }
            nil
          rescue ReturnSignal => signal
            signal.value
          ensure
            @state.pop_scope
          end
        end
      end

      def bind_params(params, args, line)
        arg_index = 0
        params.each do |param, default|
          if param.start_with?('*')
            @state.local_define(param[1..], args[arg_index..] || [])
            arg_index = args.length
            next
          end
          value = if arg_index < args.length
                    args[arg_index]
                  elsif default
                    @evaluator.parse_eval(default, line: line)
                  else
                    nil
                  end
          @state.local_define(param, value)
          arg_index += 1
        end
      end

      def with_call_depth(label)
        key = :"srsh_fn_depth_#{object_id}"
        depth = Thread.current[key].to_i
        raise RuntimeError, "#{label}: call depth exceeded" if depth >= MAX_FUNCTION_DEPTH
        Thread.current[key] = depth + 1
        yield
      ensure
        Thread.current[key] = [Thread.current[key].to_i - 1, 0].max if defined?(key)
      end

      def run_program(nodes)
        with_defer_scope { run_nodes(nodes) }
        @state.last_status
      rescue ReturnSignal => signal
        @state.last_status = signal.value.is_a?(Integer) ? signal.value : 0
      end

      def run_nodes(nodes)
        nodes.each do |node|
          case node
          when Language::Command
            execute_line(node.line)
          when Language::Assign
            assign(node)
          when Language::DestructureNode
            destructure(node)
          when Language::Emit
            @app.out.puts stringify(@evaluator.parse_eval(node.expr, line: node.number))
            @state.last_status = 0
          when Language::ExprNode
            value = @evaluator.parse_eval(node.expr, line: node.number)
            @state.last_status = value.is_a?(Integer) ? value : 0
          when Language::IfNode
            branch = @evaluator.truthy?(@evaluator.parse_eval(node.cond, line: node.number)) ? node.yes : node.no
            run_nodes(branch)
          when Language::LoopNode
            iterate(@evaluator.parse_eval(node.expr, line: node.number), node.name, node.body)
          when Language::WhileNode
            guard = 0
            while @evaluator.truthy?(@evaluator.parse_eval(node.cond, line: node.number))
              guard += 1
              raise RuntimeError, 'loop iteration safety limit exceeded' if guard > 10_000_000
              begin
                run_nodes(node.body)
              rescue NextSignal
                next
              rescue BreakSignal
                break
              end
            end
          when Language::FunctionNode, Language::TaskFunctionNode
            register_function_node(node)
          when Language::TraitNode
            register_trait_node(node)
            @state.last_status = 0
          when Language::ProtoNode
            register_proto_node(node)
            @state.local_define(node.name, Language::PrototypeRef.new(node.name))
            @state.last_status = 0
          when Language::SpaceNode
            define_space(node)
          when Language::BridgeNode
            define_bridge(node)
          when Language::UseNode
            use_module(node)
          when Language::DeferNode
            register_defer(node.body)
            @state.last_status = 0
          when Language::SlotNode
            raise RuntimeError, 'slot declarations are only valid inside proto blocks'
          when Language::CodeNode
            @state.local_define(node.name, Language::CodeValue.new(node.source, node.body.freeze))
            @state.last_status = 0
          when Language::ReturnNode
            value = node.expr.empty? ? nil : @evaluator.parse_eval(node.expr, line: node.number)
            raise ReturnSignal, value
          when Language::BreakNode
            raise BreakSignal
          when Language::NextNode
            raise NextSignal
          when Language::MatchNode
            run_match(node)
          when Language::TryNode
            run_try(node)
          else
            raise RuntimeError, "unknown program node #{node.class}"
          end
        end
      end

      def wait_job(ref)
        job = resolve_job(ref)
        raise RuntimeError, 'wait: no such job' unless job
        job.refresh!
        return 0 if job.done?
        status = wait_group(job)
        job.notified = true if job.done?
        @state.last_status = status
        status
      rescue SystemCallError => e
        @app.err.puts "wait: #{e.message}"
        1
      end

      def foreground_job(ref)
        job = resolve_job(ref)
        raise RuntimeError, 'fg: no such job' unless job
        job.refresh!
        raise RuntimeError, 'fg: job has already finished' if job.done?
        job.mark_foreground!
        begin
          Process.kill('CONT', -job.pgid)
        rescue Errno::ESRCH
          job.refresh!
          raise RuntimeError, 'fg: job has already finished'
        end
        job.mark_running!
        give_terminal(job.pgid)
        begin
          status = wait_group(job)
        ensure
          reclaim_terminal
        end
        @state.last_status = status
        status
      end

      def background_job(ref)
        job = resolve_job(ref)
        raise RuntimeError, 'bg: no such job' unless job
        job.refresh!
        raise RuntimeError, 'bg: job has already finished' if job.done?
        Process.kill('CONT', -job.pgid)
        job.mark_background!
        job.mark_running!
        0
      rescue SystemCallError => e
        @app.err.puts "bg: #{e.message}"
        1
      end

      def find_executable(name)
        return nil if name.to_s.empty?
        if name.include?('/')
          return name if File.file?(name) && File.executable?(name)
          return nil
        end
        key = [name, ENV['PATH']]
        cached = @command_cache[key]
        return cached if cached && File.executable?(cached)
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir.empty? ? '.' : dir, name)
          if File.file?(path) && File.executable?(path)
            @command_cache[key] = path
            return path
          end
        end
        nil
      end

      private

      def split_connectors(line)
        lex = Lexer.scan(line)
        out = []
        buf = []
        connector = :seq
        last_operator = nil
        lex.each do |tok|
          if tok.type == :op && %w[; && ||].include?(tok.text)
            raise ParseError, "empty command before #{tok.text}" if buf.empty?
            out << [connector, join_lexemes(buf)]
            connector = tok.text == '&&' ? :and : tok.text == '||' ? :or : :seq
            last_operator = tok.text
            buf.clear
          else
            buf << tok
            last_operator = nil
          end
        end
        if buf.empty? && %w[&& ||].include?(last_operator)
          raise ParseError, "missing command after #{last_operator}"
        end
        out << [connector, join_lexemes(buf)] unless buf.empty?
        out
      end

      def execute_pipeline(text, capture: false)
        expanded = expand_alias(text)
        if (m = expanded.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/m))
          value = begin
            Shellwords.shellsplit(m[2]).join(' ')
          rescue ArgumentError
            m[2]
          end
          ENV[m[1]] = value
          return 0
        end
        lexemes = Lexer.scan(expanded)
        background = lexemes.last&.type == :op && lexemes.last.text == '&'
        lexemes.pop if background

        parts = []
        current = []
        lexemes.each do |tok|
          if tok.type == :op && tok.text == '|'
            raise ParseError, 'empty pipeline stage' if current.empty?
            parts << current
            current = []
          else
            current << tok
          end
        end
        raise ParseError, 'empty pipeline stage' if current.empty?
        parts << current

        stages = parts.map { |part| parse_stage(part) }
        stages = normalize_legacy_external_fallbacks(stages)
        pipeline = Pipeline.new(stages, background, expanded)
        @state.run_hooks(:pre_cmd, expanded)
        status = if stages.length == 1 && !background && parent_builtin_or_function?(stages[0])
                   execute_parent(stages[0])
                 else
                   spawn_pipeline(pipeline, capture: capture)
                 end
        @state.run_hooks(:post_cmd, expanded, status)
        status
      end

      def parse_stage(lexemes)
        words = []
        stdin_path = stdout_path = stderr_path = nil
        stdout_append = stderr_append = false
        i = 0
        while i < lexemes.length
          tok = lexemes[i]
          if tok.type == :op && %w[< > >> 2> 2>>].include?(tok.text)
            path_tok = lexemes[i + 1]
            raise ParseError, "#{tok.text}: missing path" unless path_tok&.type == :word
            redirect_words = expand_command_word(path_tok.text)
            raise ParseError, "#{tok.text}: ambiguous redirect" if redirect_words.length > 1
            path = redirect_words.first
            raise ParseError, "#{tok.text}: empty path" if path.nil? || path.empty?
            case tok.text
            when '<' then stdin_path = path
            when '>' then stdout_path = path; stdout_append = false
            when '>>' then stdout_path = path; stdout_append = true
            when '2>' then stderr_path = path; stderr_append = false
            when '2>>' then stderr_path = path; stderr_append = true
            end
            i += 2
          elsif tok.type == :op
            raise ParseError, "unexpected operator #{tok.text}"
          else
            words.concat(expand_command_word(tok.text))
            i += 1
          end
        end
        raise ParseError, 'empty command' if words.empty?
        Stage.new(words, stdin_path, stdout_path, stdout_append, stderr_path, stderr_append)
      end

      def shellsplit_word(text)
        Shellwords.shellsplit(text)
      rescue ArgumentError => e
        raise ParseError, e.message
      end

      # Command words need shell expansion, not RSH's list-valued glob(). Keep
      # quoted/escaped wildcard characters literal and expand only metacharacters
      # that were actually unquoted in the command word.
      def expand_command_word(raw)
        expanded = expand_text(raw)
        word, pattern, has_glob = decode_shell_word(expanded)
        word = expand_tilde(word)
        pattern = expand_tilde(pattern)
        return [word] unless has_glob
        matches = Dir.glob(pattern).sort
        matches.empty? ? [word] : matches
      rescue ArgumentError => e
        raise ParseError, e.message
      end

      def decode_shell_word(text)
        word = +''
        pattern = +''
        quote = nil
        escaped = false
        has_glob = false
        text.each_char do |char|
          if escaped
            word << char
            pattern << (glob_meta?(char) ? "\\#{char}" : char)
            escaped = false
            next
          end
          if char == '\\' && quote != "'"
            escaped = true
            next
          end
          if quote
            if char == quote
              quote = nil
            else
              word << char
              pattern << (glob_meta?(char) ? "\\#{char}" : char)
            end
            next
          end
          if char == "'" || char == '"'
            quote = char
            next
          end
          word << char
          pattern << char
          has_glob = true if glob_meta?(char)
        end
        raise IncompleteInput, 'trailing backslash' if escaped
        raise IncompleteInput, 'unterminated quote' if quote
        [word, pattern, has_glob]
      end

      def glob_meta?(char) = char == '*' || char == '?' || char == '['

      def expand_tilde(text)
        return @app.paths.home if text == '~'
        return File.join(@app.paths.home, text[2..]) if text.start_with?('~/')
        text
      end

      def expand_alias(text)
        seen = []
        current = text
        MAX_ALIAS_DEPTH.times do
          first = Lexer.scan(current).find { |t| t.type == :word }
          break unless first
          name = Shellwords.shellsplit(first.text).first rescue first.text
          replacement = @state.aliases[name]
          break unless replacement
          raise RuntimeError, "alias loop involving #{name}" if seen.include?(name)
          seen << name
          prefix = current.index(first.text)
          current = current[0...prefix] + replacement + current[(prefix + first.text.length)..]
        end
        raise RuntimeError, 'alias expansion too deep' if seen.length >= MAX_ALIAS_DEPTH
        current
      end

      def expand_text(text)
        out = +''
        i = 0
        single = double = false
        while i < text.length
          c = text[i]

          if c == '\\' && !single && i + 1 < text.length
            # Preserve the escape for Shellwords and, critically, do not expand
            # the escaped next character (e.g. \$HOME stays literal).
            out << c << text[i + 1]
            i += 2
            next
          end

          if c == "'" && !double
            single = !single
            out << c
            i += 1
            next
          elsif c == '"' && !single
            double = !double
            out << c
            i += 1
            next
          end

          if !single && c == '$'
            if text[i + 1] == '('
              inner, finish = extract_substitution(text, i + 2)
              value = capture(inner)
              out << (double ? shell_escape_for_double(value) : Shellwords.escape(value))
              i = finish + 1
              next
            elsif text[i + 1] == '?'
              out << @state.last_status.to_s
              i += 2
              next
            elsif text[i + 1] == '!'
              out << @state.last_bg_pid.to_s
              i += 2
              next
            elsif text[i + 1] == '{'
              close = text.index('}', i + 2)
              raise ParseError, 'unterminated ${...}' unless close
              name = text[(i + 2)...close]
              out << variable_value(name, double: double)
              i = close + 1
              next
            elsif text[i + 1]&.match?(/[0-9]/)
              j = i + 1
              j += 1 while text[j]&.match?(/[0-9]/)
              out << variable_value("$#{text[(i + 1)...j]}", double: double)
              i = j
              next
            elsif text[i + 1]&.match?(/[A-Za-z_]/)
              j = i + 1
              j += 1 while text[j]&.match?(/[A-Za-z0-9_]/)
              out << variable_value(text[(i + 1)...j], double: double)
              i = j
              next
            end
          end
          out << c
          i += 1
        end
        out
      end

      def variable_value(name, double: false)
        value = if name.start_with?('$')
                  found = @state.local_defined?(name)
                  raise RuntimeError, "undefined positional #{name}" if !found && @state.options['nounset']
                  @state.local_get(name).to_s
                elsif @state.local_defined?(name)
                  @state.local_get(name).to_s
                elsif ENV.key?(name)
                  ENV[name].to_s
                else
                  raise RuntimeError, "undefined variable #{name}" if @state.options['nounset']
                  ''
                end
        double ? shell_escape_for_double(value) : Shellwords.escape(value)
      end

      def shell_escape_for_double(value)
        value.to_s.gsub(/[\\\"`$]/) { |m| "\\#{m}" }
      end

      def extract_substitution(text, start)
        depth = 1
        quote = nil
        escaped = false
        i = start
        while i < text.length
          c = text[i]
          if escaped
            escaped = false
          elsif c == '\\'
            escaped = true
          elsif quote
            quote = nil if c == quote
          elsif c == "'" || c == '"'
            quote = c
          elsif c == '(' && text[i - 1] == '$'
            depth += 1
          elsif c == ')'
            depth -= 1
            return [text[start...i], i] if depth.zero?
          end
          i += 1
        end
        raise ParseError, 'unterminated command substitution'
      end

      # The original shell only handled bare `ls [dir]` internally and sent
      # option-heavy forms to the system ls. Convert that fallback into a real
      # external pipeline stage so signals, redirections and process groups all
      # go through SRSH's normal executor instead of spawning a grandchild from
      # inside the builtin.
      def normalize_legacy_external_fallbacks(stages)
        stages.map do |stage|
          words = stage.words
          complex_ls = words[0] == 'ls' && (words.length > 2 || words[1].to_s.start_with?('-'))
          path = complex_ls ? find_executable('ls') : nil
          next stage unless path
          Stage.new([path, *words[1..]], stage.stdin_path, stage.stdout_path, stage.stdout_append,
                    stage.stderr_path, stage.stderr_append)
        end
      end

      def parent_builtin_or_function?(stage)
        name = stage.words[0]
        @app.builtins.key?(name) || function?(name)
      end

      def execute_parent(stage)
        with_parent_redirections(stage) do
          name = stage.words[0]
          if @app.builtins.key?(name)
            @app.builtins.call(name, stage.words).to_i
          else
            value = call_function(name, stage.words[1..])
            value.is_a?(Integer) ? value : 0
          end
        end
      rescue Srsh::RuntimeError => e
        @app.err.puts "#{stage.words[0]}: #{e.message}"
        1
      rescue StandardError => e
        @app.err.puts "#{stage.words[0]}: #{e.class}: #{e.message}"
        1
      end

      def with_parent_redirections(stage)
        saved = [STDIN.dup, STDOUT.dup, STDERR.dup]
        old_out = @app.out
        old_err = @app.err
        files = []
        if stage.stdin_path
          f = File.open(stage.stdin_path, 'r'); files << f; STDIN.reopen(f)
        end
        if stage.stdout_path
          f = open_output_file(stage.stdout_path, stage.stdout_append); files << f; STDOUT.reopen(f); @app.out = f
        end
        if stage.stderr_path
          f = File.open(stage.stderr_path, stage.stderr_append ? 'a' : 'w'); files << f; STDERR.reopen(f); @app.err = f
        end
        yield
      ensure
        @app.out = old_out if defined?(old_out)
        @app.err = old_err if defined?(old_err)
        STDIN.reopen(saved[0]) rescue nil
        STDOUT.reopen(saved[1]) rescue nil
        STDERR.reopen(saved[2]) rescue nil
        saved&.each { |io| io.close rescue nil }
        files&.each { |io| io.close rescue nil }
      end

      def open_output_file(path, append)
        if !append && @state.options['noclobber'] && File.exist?(path)
          raise RuntimeError, "noclobber: refusing to overwrite #{path}"
        end
        File.open(path, append ? 'a' : 'w')
      end

      def spawn_pipeline(pipeline, capture: false)
        pipes = Array.new(pipeline.stages.length - 1) { IO.pipe }
        pids = []
        pgid = nil

        pipeline.stages.each_with_index do |stage, index|
          pid = fork do
            begin
              Signal.trap('INT', 'DEFAULT')
              Signal.trap('QUIT', 'DEFAULT')
              Signal.trap('TSTP', 'DEFAULT')
              desired_pgid = pgid || Process.pid
              Process.setpgid(0, desired_pgid) rescue nil

              if index.positive?
                STDIN.reopen(pipes[index - 1][0])
              elsif stage.stdin_path
                STDIN.reopen(File.open(stage.stdin_path, 'r'))
              end

              if index < pipeline.stages.length - 1
                STDOUT.reopen(pipes[index][1])
              elsif stage.stdout_path
                STDOUT.reopen(open_output_file(stage.stdout_path, stage.stdout_append))
              end

              if stage.stderr_path
                STDERR.reopen(File.open(stage.stderr_path, stage.stderr_append ? 'a' : 'w'))
              end

              pipes.flatten.each { |io| io.close rescue nil }
              @app.out = STDOUT
              @app.err = STDERR
              status = execute_child_stage(stage)
              STDOUT.flush rescue nil
              STDERR.flush rescue nil
              exit!(status.to_i & 0xff)
            rescue Errno::ENOENT
              STDERR.puts "srsh: command not found: #{stage.words[0]}"
              exit!(127)
            rescue Errno::EACCES
              STDERR.puts "srsh: permission denied: #{stage.words[0]}"
              exit!(126)
            rescue Exception => e
              STDERR.puts "srsh: #{stage.words[0]}: #{e.class}: #{e.message}"
              exit!(125)
            end
          end

          pgid ||= pid
          Process.setpgid(pid, pgid) rescue nil
          pids << pid
        end

        pipes.flatten.each { |io| io.close rescue nil }
        job = @state.add_job(Job.new(pgid: pgid, pids: pids, command: pipeline.source, background: pipeline.background))

        if pipeline.background
          @state.last_bg_pid = pgid
          @app.out.puts "[#{job.id}] #{pgid}"
          0
        else
          # A language task can launch a process, but only the shell's owner
          # thread is allowed to hand the controlling TTY to a process group.
          manage_terminal = !capture && !@state.worker_thread?
          give_terminal(pgid) if manage_terminal
          begin
            status = wait_group(job)
          ensure
            reclaim_terminal if manage_terminal
          end
          job.notified = true if job.done?
          status
        end
      end

      def execute_child_stage(stage)
        name = stage.words[0]
        if @app.builtins.key?(name)
          @app.builtins.call(name, stage.words).to_i
        elsif function?(name)
          value = call_function(name, stage.words[1..])
          value.is_a?(Integer) ? value : 0
        else
          path = find_executable(name)
          raise Errno::ENOENT, name unless path
          exec(path, *stage.words[1..])
        end
      end

      def wait_group(job)
        statuses = {}
        remaining = job.pids.dup
        until remaining.empty?
          begin
            pid, status = Process.waitpid2(-job.pgid, Process::WUNTRACED)
            job.observe(pid, status)
            if status.stopped?
              job.mark_stopped!
              break
            elsif status.exited?
              statuses[pid] = status.exitstatus || 0
              remaining.delete(pid)
            elsif status.signaled?
              statuses[pid] = 128 + status.termsig
              remaining.delete(pid)
            end
          rescue Errno::ECHILD
            remaining.clear
            break
          rescue Interrupt
            Process.kill('INT', -job.pgid) rescue nil
          end
        end
        job.refresh! unless job.stopped?
        if @state.options['pipefail']
          job.pids.reverse_each do |pid|
            code = statuses[pid]
            return code if code && code != 0
          end
        end
        statuses.fetch(job.pids.last, 0)
      end

      def give_terminal(pgid)
        Terminal.foreground(pgid)
      end

      def reclaim_terminal
        Terminal.foreground(Process.getpgrp)
      end

      def resolve_job(ref)
        @state.prune_jobs!
        return @state.jobs.reverse.find { |j| !j.done? } if ref.nil?
        id = ref.to_s.delete_prefix('%').to_i
        @state.jobs.find { |j| j.id == id }
      end

      def join_lexemes(items)
        items.map(&:text).join(' ')
      end

      def destructure(node)
        value = @evaluator.parse_eval(node.expr, line: node.number)
        values = case value
                 when Array then value
                 when Hash then value.to_a
                 when Range then value.to_a
                 when String then value.lines(chomp: true)
                 else raise RuntimeError, "cannot destructure #{value.class}"
                 end
        index = 0
        node.names.each do |name|
          if name.start_with?('*')
            @state.local_define(name[1..], values[index..] || [])
            index = values.length
          else
            @state.local_define(name, values[index])
            index += 1
          end
        end
        @state.last_status = 0
      end

      def assign(node)
        value = @evaluator.parse_eval(node.expr, line: node.number)
        target = node.target

        if target.include?('.') && !target.start_with?('$')
          parts = target.split('.')
          owner_expr = parts[0...-1].join('.')
          key = parts[-1]
          owner = @evaluator.parse_eval(owner_expr, line: node.number)
          if owner.is_a?(Language::ObjectValue) && node.op != ':='
            rhs = value
            value = owner.update(key) { |current| assigned_value(node.op, current, rhs) }
          else
            current = node.op == ':=' ? nil : @evaluator.get_member_value(owner, key)
            value = assigned_value(node.op, current, value)
            @evaluator.set_member_value(owner, key, value)
          end
          @state.last_status = 0
          return
        end

        current = target.start_with?('$') ? ENV[target[1..]] : @state.local_get(target)
        value = assigned_value(node.op, current, value)
        if target.start_with?('$')
          raise RuntimeError, 'worker tasks cannot mutate process environment; return a value or use shared objects' if @state.worker_thread?
          ENV[target[1..]] = stringify(value)
        elsif node.op == ':='
          @state.local_define(target, value)
        else
          @state.local_set(target, value)
        end
        @state.last_status = 0
      end

      def assigned_value(op, current, value)
        case op
        when ':=' then value
        when '+=' then numeric_or_string_add(current, value)
        when '-=' then numeric(current) - numeric(value)
        when '*=' then numeric(current) * numeric(value)
        when '/='
          d = numeric(value)
          raise RuntimeError, 'division by zero' if d.zero?
          numeric(current).fdiv(d)
        when '%='
          d = numeric(value)
          raise RuntimeError, 'modulo by zero' if d.zero?
          numeric(current) % d
        when '++=' then stringify(current) + stringify(value)
        else raise RuntimeError, "unknown assignment operator #{op}"
        end
      end

      def iterate(value, name, body)
        enumerable = case value
                     when Integer then (0...value)
                     when Range, Array, Hash then value
                     when String then value.each_line.map(&:chomp)
                     else raise RuntimeError, "cannot iterate #{value.class}"
                     end
        enumerable.each do |entry|
          scope = if name.is_a?(Array)
                    values = entry.is_a?(Array) ? entry : [entry]
                    name.each_with_index.to_h { |part, index| [part, values[index]] }
                  else
                    { name => entry }
                  end
          @state.push_scope(scope)
          begin
            run_nodes(body)
          rescue NextSignal
            next
          rescue BreakSignal
            break
          ensure
            @state.pop_scope
          end
        end
      end

      def run_try(node)
        begin
          run_nodes(node.body)
        rescue StandardError => e
          raise if node.catch_body.empty?
          @state.push_scope(node.error_name => { 'type' => e.class.name, 'message' => e.message })
          begin
            run_nodes(node.catch_body)
          ensure
            @state.pop_scope
          end
        ensure
          run_nodes(node.finally_body) unless node.finally_body.empty?
        end
      end

      def run_match(node)
        value = @evaluator.parse_eval(node.expr, line: node.number)
        @state.push_scope('it' => value)
        begin
          arm = node.arms.find do |candidate|
            pattern = candidate.pattern
            next true if pattern == '_'

            if pattern.start_with?('? ')
              @evaluator.truthy?(@evaluator.parse_eval(pattern[2..].strip, line: candidate.number))
            elsif pattern.start_with?('when ')
              @evaluator.truthy?(@evaluator.parse_eval(pattern[5..].strip, line: candidate.number))
            else
              expected = @evaluator.parse_eval(pattern, line: candidate.number)
              case expected
              when Language::PrototypeRef
                value.is_a?(Language::ObjectValue) && value.proto_name == expected.name
              when Range, Array
                expected.include?(value)
              when Hash
                value.is_a?(Hash) && expected.all? { |k, v| value[k] == v || value[k.to_s] == v || value[k.to_sym] == v }
              else
                expected == value
              end
            end
          end
        ensure
          @state.pop_scope
        end
        run_nodes(arm.body) if arm
      end

      def numeric(v)
        return v if v.is_a?(Numeric)
        Float(v)
      rescue ArgumentError, TypeError
        raise RuntimeError, "expected number, got #{v.inspect}"
      end

      def numeric_or_string_add(a, b)
        return a + b if a.is_a?(Numeric) && b.is_a?(Numeric)
        numeric(a) + numeric(b)
      rescue RuntimeError
        stringify(a) + stringify(b)
      end

      def stringify(v) = @evaluator.format(v)
    end
  end
end
