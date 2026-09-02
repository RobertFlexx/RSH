require 'time'
require 'json'
require 'etc'
require 'thread'
require 'open3'
require 'shellwords'
require 'fileutils'
require_relative '../errors'
require_relative 'values'

module Srsh
  module Language
    LambdaValue = Data.define(:params, :body, :captured)
    CodeValue = Data.define(:source, :nodes)

    class Evaluator
      CACHE_LIMIT = 4096
      MAX_LAMBDA_DEPTH = 128
      MAX_FILE_READ = 16 * 1024 * 1024

      def initialize(state, executor = nil)
        @state = state
        @executor = executor
        @ast_cache = {}
        @lambda_depth = 0
      end

      attr_writer :executor

      def parse_eval(source, line: 1)
        key = [source, line]
        ast = @ast_cache[key]
        unless ast
          @ast_cache.clear if @ast_cache.length >= CACHE_LIMIT
          ast = @ast_cache[key] = ExprParser.new(source, line: line).parse
        end
        eval_ast(ast)
      end

      def truthy?(value) = !(value.nil? || value == false)

      def eval_ast(ast)
        kind = ast[0]
        case kind
        when :literal then ast[1]
        when :template
          ast[1].map { |part| part[0] == :text ? part[1] : stringify(eval_ast(part[1])) }.join
        when :capture
          raise RuntimeError, 'command capture unavailable here' unless @executor
          @executor.capture(ast[1])
        when :lambda
          LambdaValue.new(ast[1].freeze, ast[2], @state.locals_snapshot.freeze)
        when :spawn
          spawn_task(eval_ast(ast[1]), [])
        when :local
          name = ast[1]
          return @state.local_get(name) if @state.local_defined?(name)
          return FunctionRef.new(name, @state.locals_snapshot.freeze) if @executor&.function?(name)
          return PrototypeRef.new(name) if @executor&.prototype?(name)
          return ENV[name] if ENV.key?(name)
          raise RuntimeError, "undefined value #{name}" if @state.options['nounset']
          ''
        when :env
          name = ast[1]
          return @state.local_get(name) if @state.local_defined?(name)
          return ENV[name] if ENV.key?(name)
          raise RuntimeError, "undefined environment variable $#{name}" if @state.options['nounset']
          ''
        when :positional then @state.local_get("$#{ast[1]}") || ''
        when :status then @state.last_status
        when :list then ast[1].map { |x| eval_ast(x) }
        when :map then ast[1].to_h { |k, v| [eval_ast(k), eval_ast(v)] }
        when :unary then unary(ast[1], eval_ast(ast[2]))
        when :binary then binary(ast[1], ast[2], ast[3])
        when :index then index(eval_ast(ast[1]), eval_ast(ast[2]))
        when :safe_index
          owner = eval_ast(ast[1])
          safe_index(owner, owner.nil? ? nil : eval_ast(ast[2]))
        when :member then member(eval_ast(ast[1]), ast[2])
        when :safe_member
          owner = eval_ast(ast[1])
          safe_member(owner, ast[2])
        when :call then call(ast[1], ast[2].map { |a| eval_ast(a) })
        else raise RuntimeError, "unknown AST node #{kind.inspect}"
        end
      end

      def call(callee_ast, args)
        if callee_ast[0] == :local
          name = callee_ast[1]
          return @executor.instantiate(name, args) if @executor&.prototype?(name)
          return @executor.call_function(name, args) if @executor&.function?(name)
          return builtin_function(name, args) if builtin_function?(name)
        end
        fn = eval_ast(callee_ast)
        invoke_callable(fn, args)
      end

      def format(value) = stringify(value)
      def get_member_value(value, key) = member(value, key)

      def set_member_value(value, key, new_value)
        case value
        when ObjectValue
          value.set(key, new_value)
        when NamespaceValue
          raise RuntimeError, 'worker tasks cannot mutate a shared space; use an atom/object/channel' if @state.worker_thread?
          value.set(key, new_value)
        when Hash
          actual = if value.key?(key)
                     key
                   elsif value.key?(key.to_sym)
                     key.to_sym
                   else
                     key
                   end
          value[actual] = new_value
        else
          raise RuntimeError, "cannot assign .#{key} on #{type_name(value)}"
        end
        new_value
      end

      # Build a thread-isolated copy of ordinary RSH data. Explicit
      # synchronization values stay shared by reference; plain collections do not.
      def worker_snapshot(value)
        isolate_for_worker(value, {})
      end

      def isolate_for_worker(value, seen)
        case value
        when String
          value.dup
        when Array
          return seen[value.object_id] if seen.key?(value.object_id)
          copy = []
          seen[value.object_id] = copy
          value.each { |item| copy << isolate_for_worker(item, seen) }
          copy
        when Hash
          return seen[value.object_id] if seen.key?(value.object_id)
          copy = {}
          seen[value.object_id] = copy
          value.each do |key, item|
            copy[isolate_for_worker(key, seen)] = isolate_for_worker(item, seen)
          end
          copy
        when LambdaValue
          LambdaValue.new(value.params, value.body, isolate_for_worker(value.captured, seen).freeze)
        when FunctionRef
          captured = value.captured ? isolate_for_worker(value.captured, seen).freeze : nil
          FunctionRef.new(value.name, captured)
        when Range
          Range.new(isolate_for_worker(value.begin, seen), isolate_for_worker(value.end, seen), value.exclude_end?)
        # These are deliberately shareable or immutable handles.
        when ObjectValue, TaskValue, ChannelValue, AtomValue, NamespaceValue,
             NativeFunctionValue, NativePointerValue, CBufferValue, CommandValue, PrototypeRef, BoundMethodValue, NativeMethodValue, CodeValue,
             Integer, Float, TrueClass, FalseClass, NilClass, Symbol
          value
        else
          value.frozen? ? value : (value.dup rescue value)
        end
      end

      private

      BUILTIN_FUNCTIONS = %w[
        int float str bool len empty contains starts ends env rand pick status type round floor ceil sqrt clamp
        keys values join split upper lower trim abs min max cwd clock capture sh
        map filter reject fold find any all count sum sort uniq flat zip enumerate
        each take drop chunk group tap partial compose
        spawn await await_all race parallel pmap chan atom sleep cpu_count
        cmd attempt fail assert clone fields methods protoof is
        eval code run sourceof valid locals fns protos traits
        readfile writefile appendfile exists file dir glob basename dirname ext
        json json_dump lines words replace starts_with ends_with shellquote stat mkdirp rmfile cpfile mvfile
        cbuf
      ].freeze

      def builtin_function?(name) = BUILTIN_FUNCTIONS.include?(name)

      def builtin_function(name, args)
        case name
        when 'int' then numeric(args[0]).to_i
        when 'float' then numeric(args[0]).to_f
        when 'str' then stringify(args[0])
        when 'bool' then truthy?(args[0])
        when 'len' then args[0].respond_to?(:length) ? args[0].length : stringify(args[0]).length
        when 'empty' then args[0].respond_to?(:empty?) ? args[0].empty? : stringify(args[0]).empty?
        when 'contains' then contains(args[0], args[1])
        when 'starts' then stringify(args[0]).start_with?(stringify(args[1]))
        when 'ends' then stringify(args[0]).end_with?(stringify(args[1]))
        when 'env' then ENV[stringify(args[0])] || ''
        when 'rand' then Kernel.rand([numeric(args[0]).to_i, 1].max)
        when 'pick' then args.empty? ? nil : args.sample
        when 'status' then @state.last_status
        when 'type' then type_name(args[0])
        when 'round' then numeric(args[0]).round(args[1] ? numeric(args[1]).to_i : 0)
        when 'floor' then numeric(args[0]).floor
        when 'ceil' then numeric(args[0]).ceil
        when 'sqrt'
          x = numeric(args[0])
          raise RuntimeError, 'sqrt domain error' if x.negative?
          Math.sqrt(x)
        when 'clamp'
          x, lo, hi = numeric(args[0]), numeric(args[1]), numeric(args[2])
          raise RuntimeError, 'clamp lower bound is greater than upper bound' if lo > hi
          [[x, lo].max, hi].min
        when 'keys' then args[0].is_a?(Hash) ? args[0].keys : []
        when 'values' then args[0].is_a?(Hash) ? args[0].values : []
        when 'join' then Array(args[0]).join(stringify(args[1] || ''))
        when 'split' then stringify(args[0]).split(args[1] ? stringify(args[1]) : nil)
        when 'upper' then stringify(args[0]).upcase
        when 'lower' then stringify(args[0]).downcase
        when 'trim' then stringify(args[0]).strip
        when 'abs' then numeric(args[0]).abs
        when 'min' then args.compact.min
        when 'max' then args.compact.max
        when 'cwd' then Dir.pwd
        when 'clock' then Time.now.to_f
        when 'capture'
          require_executor!('capture')
          @executor.capture(stringify(args[0]))
        when 'sh'
          require_executor!('sh')
          raise RuntimeError, 'sh() cannot take foreground job control from an RSH worker; use capture()' if @state.worker_thread?
          @executor.execute_line(stringify(args[0]))

        when 'map'
          sequence_map(args[0]) { |*item| invoke_callable(args[1], item) }
        when 'filter'
          sequence_select(args[0]) { |*item| truthy?(invoke_callable(args[1], item)) }
        when 'reject'
          sequence_select(args[0]) { |*item| !truthy?(invoke_callable(args[1], item)) }
        when 'fold'
          acc = args[1]
          sequence_each(args[0]) { |*item| acc = invoke_callable(args[2], [acc, *item]) }
          acc
        when 'find'
          found = nil
          hit = false
          sequence_each(args[0]) do |*item|
            next unless truthy?(invoke_callable(args[1], item))
            found = item.length == 1 ? item[0] : item
            hit = true
            break
          end
          hit ? found : nil
        when 'any'
          fn = args[1]
          result = false
          sequence_each(args[0]) do |*item|
            value = fn ? invoke_callable(fn, item) : (item.length == 1 ? item[0] : item)
            if truthy?(value)
              result = true
              break
            end
          end
          result
        when 'all'
          fn = args[1]
          result = true
          sequence_each(args[0]) do |*item|
            value = fn ? invoke_callable(fn, item) : (item.length == 1 ? item[0] : item)
            unless truthy?(value)
              result = false
              break
            end
          end
          result
        when 'count'
          fn = args[1]
          n = 0
          sequence_each(args[0]) do |*item|
            value = fn ? invoke_callable(fn, item) : (item.length == 1 ? item[0] : item)
            n += 1 if fn.nil? || truthy?(value)
          end
          n
        when 'sum'
          fn = args[1]
          total = 0
          sequence_each(args[0]) do |*item|
            value = fn ? invoke_callable(fn, item) : (item.length == 1 ? item[0] : item)
            total += numeric(value)
          end
          total
        when 'sort'
          seq = sequence_values(args[0])
          args[1] ? seq.sort_by { |item| invoke_callable(args[1], [item]) } : seq.sort
        when 'uniq' then sequence_values(args[0]).uniq
        when 'flat' then sequence_values(args[0]).flatten(args[1] ? numeric(args[1]).to_i : 1)
        when 'zip'
          left = sequence_values(args[0])
          right = sequence_values(args[1])
          left.zip(right)
        when 'enumerate'
          sequence_values(args[0]).each_with_index.map { |value, index| [index, value] }
        when 'each'
          sequence_each(args[0]) { |*item| invoke_callable(args[1], item) }
          args[0]
        when 'take' then sequence_values(args[0]).first(numeric(args[1] || 1).to_i)
        when 'drop' then sequence_values(args[0]).drop(numeric(args[1] || 1).to_i)
        when 'chunk'
          n = numeric(args[1] || 1).to_i
          raise RuntimeError, 'chunk size must be positive' if n <= 0
          sequence_values(args[0]).each_slice(n).to_a
        when 'group'
          fn = args[1]
          sequence_values(args[0]).group_by { |item| invoke_callable(fn, [item]) }
        when 'tap'
          invoke_callable(args[1], [args[0]])
          args[0]
        when 'partial'
          fn = args[0]
          prefix = args[1..].freeze
          proc { |*rest| invoke_callable(fn, [*prefix, *rest]) }
        when 'compose'
          fns = args.freeze
          proc do |*input|
            raise RuntimeError, 'compose() needs at least one callable' if fns.empty?
            value = invoke_callable(fns[-1], input)
            fns[0...-1].reverse_each { |fn| value = invoke_callable(fn, [value]) }
            value
          end

        when 'spawn'
          fn = args[0]
          spawn_task(fn, args[1..])
        when 'await'
          task = args[0]
          raise RuntimeError, 'await() expects a task' unless task.is_a?(TaskValue)
          task.await(args[1])
        when 'await_all'
          tasks = sequence_values(args[0])
          raise RuntimeError, 'await_all() expects tasks' unless tasks.all? { |t| t.is_a?(TaskValue) }
          values = []
          begin
            tasks.each { |task| values << task.await }
          rescue StandardError
            tasks.each { |task| task.cancel unless task.done? }
            raise
          end
          values
        when 'race'
          tasks = sequence_values(args[0])
          raise RuntimeError, 'race() requires at least one task' if tasks.empty?
          raise RuntimeError, 'race() expects tasks' unless tasks.all? { |t| t.is_a?(TaskValue) }
          winner = nil
          begin
            loop do
              winner = tasks.find(&:done?)
              break if winner
              Kernel.sleep(0.001)
            end
            winner.await
          ensure
            tasks.each { |task| task.cancel if task != winner && !task.done? }
          end
        when 'parallel'
          parallel_map(args[0], args[1], args[2])
        when 'pmap'
          process_map(args[0], args[1], args[2])
        when 'chan' then ChannelValue.new(args[0] ? numeric(args[0]).to_i : 0)
        when 'atom' then AtomValue.new(args[0])
        when 'sleep'
          Kernel.sleep(numeric(args[0] || 0).to_f)
          nil
        when 'cpu_count' then Etc.nprocessors
        when 'cmd'
          argv = args.length == 1 && args[0].is_a?(Array) ? args[0] : args
          CommandValue.new(argv.map { |part| stringify(part) })
        when 'attempt'
          begin
            { 'ok' => true, 'value' => invoke_callable(args[0], args[1..]), 'error' => nil }
          rescue StandardError => e
            { 'ok' => false, 'value' => nil, 'error' => { 'type' => e.class.name, 'message' => e.message } }
          end
        when 'fail'
          raise RuntimeError, stringify(args[0] || 'failure')
        when 'assert'
          raise RuntimeError, stringify(args[1] || 'assertion failed') unless truthy?(args[0])
          args[0]

        when 'clone'
          value = args[0]
          value.is_a?(ObjectValue) ? value.copy : (value.dup rescue value)
        when 'fields'
          value = args[0]
          value.is_a?(ObjectValue) ? value.fields : (value.is_a?(Hash) ? value.dup : {})
        when 'methods'
          value = args[0]
          value.is_a?(ObjectValue) && @executor ? @executor.prototype_methods(value.proto_name) : native_methods_for(value)
        when 'protoof'
          value = args[0]
          value.is_a?(ObjectValue) ? PrototypeRef.new(value.proto_name) : nil
        when 'is'
          value, proto = args[0], args[1]
          pname = proto.is_a?(PrototypeRef) ? proto.name : stringify(proto)
          value.is_a?(ObjectValue) && value.proto_name == pname

        when 'eval'
          parse_eval(stringify(args[0]))
        when 'code'
          source = stringify(args[0])
          CodeValue.new(source, ProgramParser.new(source).parse.freeze)
        when 'run'
          require_executor!('run')
          value = args[0]
          nodes = value.is_a?(CodeValue) ? value.nodes : ProgramParser.new(stringify(value)).parse
          @executor.run_program(nodes)
        when 'sourceof'
          value = args[0]
          value.is_a?(CodeValue) ? value.source : stringify(value)
        when 'valid'
          source = stringify(args[0])
          mode = stringify(args[1] || 'program')
          begin
            mode == 'expr' ? ExprParser.new(source).parse : ProgramParser.new(source).parse
            true
          rescue ParseError
            false
          end
        when 'locals' then @state.locals_snapshot
        when 'fns' then @state.functions.keys.sort
        when 'protos' then @state.prototypes.keys.sort
        when 'traits' then @state.traits.keys.sort

        when 'readfile'
          path = stringify(args[0])
          size = File.size(path)
          raise RuntimeError, "readfile: file exceeds #{MAX_FILE_READ} bytes" if size > MAX_FILE_READ
          File.binread(path)
        when 'writefile'
          path = stringify(args[0])
          data = stringify(args[1])
          File.binwrite(path, data)
        when 'appendfile'
          path = stringify(args[0])
          data = stringify(args[1])
          File.open(path, 'ab') { |f| f.write(data) }
        when 'exists' then File.exist?(stringify(args[0]))
        when 'file' then File.file?(stringify(args[0]))
        when 'dir' then File.directory?(stringify(args[0]))
        when 'glob' then Dir.glob(stringify(args[0])).sort
        when 'basename' then File.basename(stringify(args[0]))
        when 'dirname' then File.dirname(stringify(args[0]))
        when 'ext' then File.extname(stringify(args[0]))
        when 'json' then JSON.parse(stringify(args[0]))
        when 'json_dump' then JSON.generate(args[0])
        when 'lines' then stringify(args[0]).lines(chomp: true)
        when 'words' then stringify(args[0]).split
        when 'replace' then stringify(args[0]).gsub(stringify(args[1]), stringify(args[2]))
        when 'starts_with' then stringify(args[0]).start_with?(stringify(args[1]))
        when 'ends_with' then stringify(args[0]).end_with?(stringify(args[1]))
        when 'shellquote' then Shellwords.escape(stringify(args[0]))
        when 'stat'
          st = File.stat(stringify(args[0]))
          { 'size' => st.size, 'mode' => st.mode, 'uid' => st.uid, 'gid' => st.gid,
            'mtime' => st.mtime.to_f, 'file' => st.file?, 'dir' => st.directory?, 'symlink' => st.symlink? }
        when 'mkdirp' then FileUtils.mkdir_p(stringify(args[0])); stringify(args[0])
        when 'rmfile' then FileUtils.rm_f(stringify(args[0])); true
        when 'cpfile' then FileUtils.cp(stringify(args[0]), stringify(args[1])); stringify(args[1])
        when 'mvfile' then FileUtils.mv(stringify(args[0]), stringify(args[1])); stringify(args[1])
        when 'cbuf' then CBufferValue.new(numeric(args[0]).to_i)
        else raise RuntimeError, "unknown function #{name}"
        end
      rescue SystemCallError => e
        raise RuntimeError, "#{name}: #{e.message}"
      rescue JSON::ParserError, JSON::GeneratorError => e
        raise RuntimeError, "#{name}: #{e.message}"
      end

      def require_executor!(feature)
        raise RuntimeError, "#{feature}() unavailable here" unless @executor
      end

      def invoke_callable(fn, args)
        case fn
        when LambdaValue
          call_lambda(fn, args)
        when FunctionRef
          require_executor!('function call')
          @executor.call_function(fn.name, args, call_seed: fn.captured)
        when BoundMethodValue
          require_executor!('method call')
          @executor.call_method(fn.receiver, fn.name, args)
        when NativeMethodValue
          native_method(fn.receiver, fn.name, args)
        when PrototypeRef
          require_executor!('prototype construction')
          @executor.instantiate(fn.name, args)
        when Proc, Method
          fn.call(*args)
        when String
          if @executor&.function?(fn)
            @executor.call_function(fn, args)
          elsif builtin_function?(fn)
            builtin_function(fn, args)
          else
            raise RuntimeError, "unknown callable #{fn.inspect}"
          end
        else
          if fn.respond_to?(:call)
            fn.call(*args)
          else
            raise RuntimeError, 'value is not callable'
          end
        end
      end

      def call_lambda(fn, args)
        key = :"srsh_lambda_depth_#{object_id}"
        depth = Thread.current[key].to_i
        raise RuntimeError, 'lambda call depth exceeded' if depth >= MAX_LAMBDA_DEPTH
        Thread.current[key] = depth + 1
        pushed = false
        scope = fn.captured.dup
        args.each_with_index { |value, index| scope["$#{index + 1}"] = value }
        arg_index = 0
        fn.params.each do |param|
          if param.start_with?('*')
            scope[param[1..]] = args[arg_index..] || []
            arg_index = args.length
          else
            scope[param] = args[arg_index]
            arg_index += 1
          end
        end
        scope['$0'] = '<lambda>'
        @state.push_scope(scope)
        pushed = true
        eval_ast(fn.body)
      ensure
        @state.pop_scope if pushed
        Thread.current[key] = [Thread.current[key].to_i - 1, 0].max if defined?(key)
      end

      def unary(op, value)
        case op
        when '-' then -numeric(value)
        when '+' then numeric(value)
        when 'not', '!' then !truthy?(value)
        else raise RuntimeError, "unknown unary operator #{op}"
        end
      end

      def binary(op, left_ast, right_ast)
        if op == '|>'
          left = eval_ast(left_ast)
          return pipe(left, right_ast)
        elsif op == 'and' || op == '&&'
          left = eval_ast(left_ast)
          return left unless truthy?(left)
          return eval_ast(right_ast)
        elsif op == 'or' || op == '||'
          left = eval_ast(left_ast)
          return left if truthy?(left)
          return eval_ast(right_ast)
        elsif op == '??'
          left = eval_ast(left_ast)
          return left unless left.nil?
          return eval_ast(right_ast)
        end

        a = eval_ast(left_ast)
        b = eval_ast(right_ast)
        case op
        when '+' then arithmetic_add(a, b)
        when '++' then stringify(a) + stringify(b)
        when '-' then numeric(a) - numeric(b)
        when '*' then numeric(a) * numeric(b)
        when '/'
          d = numeric(b)
          raise RuntimeError, 'division by zero' if d.zero?
          numeric(a).fdiv(d)
        when '%'
          d = numeric(b)
          raise RuntimeError, 'modulo by zero' if d.zero?
          numeric(a) % d
        when '**' then numeric(a)**numeric(b)
        when '==' then compare(a, b).zero?
        when '!=' then !compare(a, b).zero?
        when '===' then a.eql?(b)
        when '!==' then !a.eql?(b)
        when '<' then compare(a, b).negative?
        when '<=' then compare(a, b) <= 0
        when '>' then compare(a, b).positive?
        when '>=' then compare(a, b) >= 0
        when '=~' then !!(stringify(a) =~ Regexp.new(stringify(b)))
        when '!~' then !(stringify(a) =~ Regexp.new(stringify(b)))
        when 'in' then membership(a, b)
        when '..' then Range.new(numeric_or_same(a), numeric_or_same(b), false)
        when '..<' then Range.new(numeric_or_same(a), numeric_or_same(b), true)
        else raise RuntimeError, "unknown operator #{op}"
        end
      rescue RegexpError => e
        raise RuntimeError, "bad regex: #{e.message}"
      end

      def pipe(value, right_ast)
        case right_ast[0]
        when :call
          callee = right_ast[1]
          args = [value] + right_ast[2].map { |arg| eval_ast(arg) }
          call(callee, args)
        when :local
          name = right_ast[1]
          return @executor.call_function(name, [value]) if @executor&.function?(name)
          return builtin_function(name, [value]) if builtin_function?(name)
          invoke_callable(eval_ast(right_ast), [value])
        when :lambda
          invoke_callable(eval_ast(right_ast), [value])
        else
          invoke_callable(eval_ast(right_ast), [value])
        end
      end

      def sequence_each(value, &block)
        case value
        when Hash
          value.each { |k, v| block.call(k, v) }
        when Range, Array
          value.each { |item| block.call(item) }
        when String
          value.each_line(chomp: true) { |line| block.call(line) }
        else
          raise RuntimeError, "expected iterable, got #{type_name(value)}"
        end
      end

      def sequence_map(value)
        out = []
        sequence_each(value) { |*item| out << yield(*item) }
        out
      end

      def sequence_select(value)
        if value.is_a?(Hash)
          out = {}
          sequence_each(value) { |k, v| out[k] = v if yield(k, v) }
          out
        else
          out = []
          sequence_each(value) do |*item|
            value = item.length == 1 ? item[0] : item
            out << value if yield(*item)
          end
          out
        end
      end

      def sequence_values(value)
        case value
        when Hash then value.to_a
        when Range, Array then value.to_a
        when String then value.lines(chomp: true)
        else raise RuntimeError, "expected iterable, got #{type_name(value)}"
        end
      end

      def compare(a, b)
        if numeric_candidate?(a) && numeric_candidate?(b)
          numeric(a) <=> numeric(b)
        else
          stringify(a) <=> stringify(b)
        end
      end

      def numeric_candidate?(value)
        return true if value.is_a?(Numeric)
        value.to_s.strip.match?(/\A[+-]?(?:\d+|\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?\z/)
      end

      def numeric(value)
        return value if value.is_a?(Numeric)
        s = value.to_s.strip
        return s.to_i if s.match?(/\A[+-]?\d+\z/)
        return s.to_f if s.match?(/\A[+-]?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?\z/)
        raise RuntimeError, "expected number, got #{value.inspect}"
      end

      def numeric_or_same(value)
        numeric(value)
      rescue RuntimeError
        value
      end

      def stringify(value)
        case value
        when nil then ''
        when true then 'yes'
        when false then 'no'
        when CodeValue then value.source
        when Array then '[' + value.map { |v| repr(v) }.join(', ') + ']'
        when Hash then '%[' + value.map { |k, v| "#{repr_key(k)}: #{repr(v)}" }.join(', ') + ']'
        else value.to_s
        end
      end

      def repr(value)
        case value
        when nil then 'void'
        when true then 'yes'
        when false then 'no'
        when String then value.inspect
        when Array then '[' + value.map { |v| repr(v) }.join(', ') + ']'
        when Hash then '%[' + value.map { |k, v| "#{repr_key(k)}: #{repr(v)}" }.join(', ') + ']'
        when Range then "#{repr(value.begin)}#{value.exclude_end? ? '..<' : '..'}#{repr(value.end)}"
        else value.to_s
        end
      end

      def repr_key(key)
        key.is_a?(String) && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? key : repr(key)
      end

      def arithmetic_add(a, b)
        return a + b if a.is_a?(Numeric) && b.is_a?(Numeric)
        numeric(a) + numeric(b)
      rescue RuntimeError
        stringify(a) + stringify(b)
      end

      def membership(a, b)
        case b
        when Range, Array, Hash, String then b.include?(a)
        else false
        end
      end

      def contains(a, b)
        case a
        when Hash then a.key?(b)
        else a.respond_to?(:include?) ? a.include?(b) : stringify(a).include?(stringify(b))
        end
      end

      def index(value, key)
        raise RuntimeError, "cannot index #{type_name(value)}" unless value.respond_to?(:[])
        value[key]
      rescue TypeError, IndexError => e
        raise RuntimeError, "bad index: #{e.message}"
      end

      def safe_index(value, key)
        return nil if value.nil? || !value.respond_to?(:[])
        value[key]
      rescue StandardError
        nil
      end

      def member(value, key)
        key = key.to_s
        if value.is_a?(CommandValue)
          return NativeMethodValue.new(value, key) if %w[capture result check run task argv].include?(key)
          raise RuntimeError, "command has no member .#{key}"
        end

        if value.is_a?(NamespaceValue)
          return value.get(key) if value.member?(key)
          return NativeMethodValue.new(value, key) if %w[keys has].include?(key)
          raise RuntimeError, "space #{value.name} has no member .#{key}"
        end

        if value.is_a?(ObjectValue)
          return value.get(key) if value.field?(key)
          return BoundMethodValue.new(value, key) if @executor&.object_method?(value, key)
          return NativeMethodValue.new(value, key) if %w[fields methods proto clone is].include?(key)
          raise RuntimeError, "#{value.proto_name} has no member .#{key}"
        end

        if value.is_a?(PrototypeRef)
          return NativeMethodValue.new(value, key) if key == 'new'
          raise RuntimeError, "prototype #{value.name} has no member .#{key}"
        end

        if value.is_a?(Hash)
          return value[key] if value.key?(key)
          sym = key.to_sym
          return value[sym] if value.key?(sym)
        end

        return NativeMethodValue.new(value, key) if native_methods_for(value).include?(key)
        raise RuntimeError, "cannot access .#{key} on #{type_name(value)}"
      end

      def safe_member(value, key)
        return nil if value.nil?
        member(value, key)
      rescue RuntimeError
        nil
      end

      def native_methods_for(value)
        case value
        when CommandValue then %w[capture result check run task argv]
        when NamespaceValue then %w[keys has]
        when ObjectValue then %w[fields methods proto clone is]
        when TaskValue then %w[await done status cancel]
        when ChannelValue then %w[send recv try_recv close closed size]
        when AtomValue then %w[get set swap]
        when CBufferValue then %w[size address read write string clear ptr]
        when NativePointerValue then %w[address null]
        when Array, Range then %w[len empty map filter reject each fold sum sort uniq first last take drop join]
        when String then %w[len empty upper lower trim split lines contains starts ends]
        when Hash then %w[len empty keys values get has map filter each]
        else []
        end
      end

      def native_method(receiver, name, args)
        case receiver
        when CommandValue
          case name
          when 'argv' then receiver.argv.dup
          when 'result' then run_argv(receiver.argv)
          when 'capture'
            result = run_argv(receiver.argv)
            @state.last_status = result['status']
            result['out']
          when 'check'
            result = run_argv(receiver.argv)
            @state.last_status = result['status']
            if result['status'] != 0
              detail = result['err'].to_s.strip
              detail = detail.empty? ? '' : ": #{detail}"
              raise RuntimeError, "command failed with status #{result['status']}: #{receiver.argv[0]}#{detail}"
            end
            result
          when 'run'
            raise RuntimeError, 'command.run() cannot own the terminal from a worker task; use .result()/.capture()' if @state.worker_thread?
            ok = system(*receiver.argv)
            status = $?.exitstatus || (ok ? 0 : 1)
            @state.last_status = status
            status
          when 'task'
            TaskValue.new { run_argv(receiver.argv) }
          else raise RuntimeError, "unknown command method .#{name}"
          end
        when NamespaceValue
          case name
          when 'keys' then receiver.keys
          when 'has' then receiver.member?(stringify(args[0]))
          else raise RuntimeError, "unknown space method .#{name}"
          end
        when ObjectValue
          case name
          when 'fields' then receiver.fields
          when 'methods' then @executor ? @executor.prototype_methods(receiver.proto_name) : []
          when 'proto' then PrototypeRef.new(receiver.proto_name)
          when 'clone' then receiver.copy
          when 'is'
            proto = args[0]
            pname = proto.is_a?(PrototypeRef) ? proto.name : stringify(proto)
            receiver.proto_name == pname
          else raise RuntimeError, "unknown object method .#{name}"
          end
        when TaskValue
          case name
          when 'await' then receiver.await(args[0])
          when 'done' then receiver.done?
          when 'status' then receiver.status
          when 'cancel' then receiver.cancel
          else raise RuntimeError, "unknown task method .#{name}"
          end
        when ChannelValue
          case name
          when 'send' then receiver.send_value(args[0])
          when 'recv' then receiver.recv(args[0])
          when 'try_recv' then receiver.try_recv
          when 'close' then receiver.close
          when 'closed' then receiver.closed?
          when 'size' then receiver.size
          else raise RuntimeError, "unknown channel method .#{name}"
          end
        when AtomValue
          case name
          when 'get' then receiver.get
          when 'set' then receiver.set(args[0])
          when 'swap'
            raise RuntimeError, 'atom.swap() expects a callable' unless args[0]
            receiver.swap { |old| invoke_callable(args[0], [old]) }
          else raise RuntimeError, "unknown atom method .#{name}"
          end
        when CBufferValue
          case name
          when 'size' then receiver.size
          when 'address' then receiver.address
          when 'ptr' then NativePointerValue.new(receiver.pointer)
          when 'clear'
            receiver.pointer[0, receiver.size] = "\0" * receiver.size
            receiver
          when 'read'
            offset = args[0] ? numeric(args[0]).to_i : 0
            length = args[1] ? numeric(args[1]).to_i : receiver.size - offset
            raise RuntimeError, 'cbuf.read() range is outside buffer' if offset.negative? || length.negative? || offset + length > receiver.size
            receiver.pointer[offset, length]
          when 'string'
            max = args[0] ? numeric(args[0]).to_i : receiver.size
            raise RuntimeError, 'cbuf.string() length is outside buffer' if max.negative? || max > receiver.size
            data = receiver.pointer[0, max]
            data.split("\0", 2).first.to_s
          when 'write'
            data = stringify(args[0]).b
            offset = args[1] ? numeric(args[1]).to_i : 0
            raise RuntimeError, 'cbuf.write() range is outside buffer' if offset.negative? || offset + data.bytesize > receiver.size
            receiver.pointer[offset, data.bytesize] = data
            data.bytesize
          else raise RuntimeError, "unknown cbuf method .#{name}"
          end
        when NativePointerValue
          case name
          when 'address' then receiver.address
          when 'null' then receiver.null?
          else raise RuntimeError, "unknown pointer method .#{name}"
          end
        when PrototypeRef
          raise RuntimeError, "unknown prototype method .#{name}" unless name == 'new'
          require_executor!('prototype construction')
          @executor.instantiate(receiver.name, args)
        when Array, Range
          sequence_native_method(receiver, name, args)
        when String
          string_native_method(receiver, name, args)
        when Hash
          hash_native_method(receiver, name, args)
        else
          raise RuntimeError, "unknown method .#{name} for #{type_name(receiver)}"
        end
      end

      def sequence_native_method(receiver, name, args)
        case name
        when 'len' then receiver.length
        when 'empty' then receiver.empty?
        when 'map' then builtin_function('map', [receiver, args[0]])
        when 'filter' then builtin_function('filter', [receiver, args[0]])
        when 'reject' then builtin_function('reject', [receiver, args[0]])
        when 'each' then builtin_function('each', [receiver, args[0]])
        when 'fold' then builtin_function('fold', [receiver, args[0], args[1]])
        when 'sum' then builtin_function('sum', [receiver, args[0]])
        when 'sort' then builtin_function('sort', [receiver, args[0]])
        when 'uniq' then sequence_values(receiver).uniq
        when 'first' then sequence_values(receiver).first(args[0] ? numeric(args[0]).to_i : 1).then { |v| args[0] ? v : v.first }
        when 'last' then args[0] ? sequence_values(receiver).last(numeric(args[0]).to_i) : sequence_values(receiver).last
        when 'take' then builtin_function('take', [receiver, args[0]])
        when 'drop' then builtin_function('drop', [receiver, args[0]])
        when 'join' then sequence_values(receiver).join(stringify(args[0] || ''))
        else raise RuntimeError, "unknown sequence method .#{name}"
        end
      end

      def string_native_method(receiver, name, args)
        case name
        when 'len' then receiver.length
        when 'empty' then receiver.empty?
        when 'upper' then receiver.upcase
        when 'lower' then receiver.downcase
        when 'trim' then receiver.strip
        when 'split' then receiver.split(args[0] ? stringify(args[0]) : nil)
        when 'lines' then receiver.lines(chomp: true)
        when 'contains' then receiver.include?(stringify(args[0]))
        when 'starts' then receiver.start_with?(stringify(args[0]))
        when 'ends' then receiver.end_with?(stringify(args[0]))
        else raise RuntimeError, "unknown string method .#{name}"
        end
      end

      def hash_native_method(receiver, name, args)
        case name
        when 'len' then receiver.length
        when 'empty' then receiver.empty?
        when 'keys' then receiver.keys
        when 'values' then receiver.values
        when 'get' then receiver.fetch(args[0], args[1])
        when 'has' then receiver.key?(args[0])
        when 'map' then builtin_function('map', [receiver, args[0]])
        when 'filter' then builtin_function('filter', [receiver, args[0]])
        when 'each' then builtin_function('each', [receiver, args[0]])
        else raise RuntimeError, "unknown map method .#{name}"
        end
      end

      def run_argv(argv)
        max = 4 * 1024 * 1024
        stdin = stdout = stderr = waiter = nil
        buffers = {}
        spawned = false

        begin
          stdin, stdout, stderr, waiter = Open3.popen3(*argv)
          spawned = true
          stdin.close
          buffers = { stdout => +"", stderr => +"" }
          open = buffers.keys.dup

          until open.empty?
            ready = IO.select(open, nil, nil, 0.1)&.first || []
            ready.each do |io|
              begin
                chunk = io.read_nonblock(16 * 1024)
                buffer = buffers.fetch(io)
                if buffer.bytesize + chunk.bytesize > max
                  raise RuntimeError, "command output exceeds #{max} bytes"
                end
                buffer << chunk
              rescue IO::WaitReadable
              rescue EOFError
                open.delete(io)
                io.close rescue nil
              end
            end
          end

          status = waiter.value
          spawned = false
          {
            'out' => buffers.fetch(stdout, +""),
            'err' => buffers.fetch(stderr, +""),
            'status' => status.exitstatus || (status.signaled? ? 128 + status.termsig : 1)
          }
        ensure
          stdin.close rescue nil
          stdout.close rescue nil
          stderr.close rescue nil
          terminate_argv_process(waiter) if spawned && waiter
        end
      rescue Errno::ENOENT
        raise RuntimeError, "command not found: #{argv[0]}"
      rescue Errno::EACCES
        raise RuntimeError, "permission denied: #{argv[0]}"
      end

      def terminate_argv_process(waiter)
        return unless waiter
        pid = waiter.pid
        Process.kill('TERM', pid) rescue nil
        return waiter.value if waiter.join(0.25)

        Process.kill('KILL', pid) rescue nil
        waiter.join(1.0)
        waiter.value rescue nil
      end

      def spawn_task(fn, args)
        worker_fn = worker_snapshot(fn)
        worker_args = worker_snapshot(args)
        TaskValue.new { concurrent_invoke(worker_fn, worker_args) }
      end

      def concurrent_invoke(fn, args)
        worker = self.class.new(@state, @executor)
        worker.send(:invoke_callable, fn, args)
      end

      def parallel_map(value, fn, workers_arg)
        items = sequence_values(value)
        return [] if items.empty?
        workers = workers_arg ? numeric(workers_arg).to_i : Etc.nprocessors
        workers = [[workers, 1].max, items.length, 64].min
        queue = Queue.new
        items.each_with_index { |item, index| queue << [index, item] }
        results = Array.new(items.length)
        errors = Queue.new

        threads = Array.new(workers) do
          Thread.new do
            worker = self.class.new(@state, @executor)
            worker_fn = worker.worker_snapshot(fn)
            loop do
              pair = queue.pop(true) rescue nil
              break unless pair
              index, item = pair
              begin
                worker_item = worker.worker_snapshot(item)
                results[index] = worker.send(:invoke_callable, worker_fn, [worker_item])
              rescue StandardError => e
                errors << e
                break
              end
            end
          end
        end
        threads.each(&:join)
        raise errors.pop unless errors.empty?
        results
      end

      def process_map(value, fn, workers_arg)
        items = sequence_values(value)
        return [] if items.empty?
        return parallel_map(value, fn, workers_arg) unless Process.respond_to?(:fork)

        workers = workers_arg ? numeric(workers_arg).to_i : Etc.nprocessors
        workers = [[workers, 1].max, items.length, 32].min
        chunks = Array.new(workers) { [] }
        items.each_with_index { |item, index| chunks[index % workers] << [index, item] }
        children = []

        chunks.each do |chunk|
          reader, writer = IO.pipe
          pid = fork do
            reader.close
            begin
              worker = self.class.new(@state, @executor)
              data = chunk.map do |index, item|
                [index, worker.send(:invoke_callable, fn, [item])]
              end
              Marshal.dump({ ok: true, data: data }, writer)
            rescue Exception => e
              begin
                Marshal.dump({ ok: false, error: "#{e.class}: #{e.message}" }, writer)
              rescue StandardError
              end
            ensure
              writer.close rescue nil
              exit!(0)
            end
          end
          writer.close
          children << [pid, reader]
        end

        results = Array.new(items.length)
        errors = []
        children.each do |pid, reader|
          begin
            packet = Marshal.load(reader)
            if packet[:ok]
              packet[:data].each { |index, item| results[index] = item }
            else
              errors << packet[:error]
            end
          rescue EOFError, TypeError, ArgumentError => e
            errors << "worker #{pid}: #{e.class}: #{e.message}"
          ensure
            reader.close rescue nil
            Process.waitpid(pid) rescue nil
          end
        end
        raise RuntimeError, "pmap worker failed: #{errors.first}" unless errors.empty?
        results
      end

      def type_name(value)
        case value
        when nil then 'void'
        when Integer then 'int'
        when Float then 'float'
        when String then 'str'
        when Array then 'list'
        when Hash then 'map'
        when Range then 'range'
        when TrueClass, FalseClass then 'bool'
        when LambdaValue then 'lambda'
        when CodeValue then 'code'
        when CommandValue then 'command'
        when NativeLibraryValue then 'bridge'
        when NamespaceValue then 'space'
        when FunctionRef then 'function'
        when PrototypeRef then 'proto'
        when ObjectValue then value.proto_name
        when TaskValue then 'task'
        when ChannelValue then 'chan'
        when AtomValue then 'atom'
        when NativeFunctionValue then 'cfn'
        when NativePointerValue then 'ptr'
        when CBufferValue then 'cbuf'
        when BoundMethodValue, NativeMethodValue then 'method'
        else value.class.name
        end
      end
    end
  end
end
