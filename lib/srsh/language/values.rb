require 'thread'
require 'fiddle'
require_relative '../errors'

module Srsh
  module Language
    class FunctionRef
      attr_reader :name, :captured
      def initialize(name, captured = nil)
        @name = name.to_s.freeze
        @captured = captured
      end
      def to_s = "fn<#{name}>"
      def inspect = to_s
    end

    PrototypeRef = Data.define(:name) do
      def to_s = name.to_s
      def inspect = to_s
    end
    BoundMethodValue = Data.define(:receiver, :name)
    NativeMethodValue = Data.define(:receiver, :name)



    class NativePointerValue
      attr_reader :pointer
      def initialize(pointer)
        @pointer = pointer.is_a?(Fiddle::Pointer) ? pointer : Fiddle::Pointer.new(pointer.to_i)
      end
      def address = @pointer.to_i
      def null? = address.zero?
      def to_s = "ptr<0x#{address.to_s(16)}>"
      def inspect = to_s
    end

    class CBufferValue
      attr_reader :pointer, :size
      def initialize(size)
        @size = Integer(size)
        raise RuntimeError, 'cbuf() size must be between 1 and 64 MiB' unless @size.between?(1, 64 * 1024 * 1024)
        @pointer = Fiddle::Pointer.malloc(@size, Fiddle::RUBY_FREE)
        @pointer[0, @size] = "\0" * @size
      end
      def address = @pointer.to_i
      def to_s = "cbuf<#{@size}@0x#{address.to_s(16)}>"
      def inspect = to_s
    end

    class NativeFunctionValue
      TYPES = {
        'void' => Fiddle::TYPE_VOID,
        'bool' => Fiddle::TYPE_BOOL,
        'i8' => Fiddle::TYPE_INT8_T, 'u8' => Fiddle::TYPE_UINT8_T,
        'i16' => Fiddle::TYPE_INT16_T, 'u16' => Fiddle::TYPE_UINT16_T,
        'i32' => Fiddle::TYPE_INT32_T, 'u32' => Fiddle::TYPE_UINT32_T,
        'i64' => Fiddle::TYPE_INT64_T, 'u64' => Fiddle::TYPE_UINT64_T,
        'isize' => Fiddle::TYPE_INTPTR_T, 'usize' => Fiddle::TYPE_SIZE_T,
        'f32' => Fiddle::TYPE_FLOAT, 'f64' => Fiddle::TYPE_DOUBLE,
        'cstr' => Fiddle::TYPE_CONST_STRING, 'ptr' => Fiddle::TYPE_VOIDP
      }.freeze

      attr_reader :name, :params, :result

      def initialize(handle, name, params, result)
        @name = name.to_s.freeze
        @params = params.map(&:to_s).freeze
        @result = result.to_s.freeze
        bad = (@params + [@result]).reject { |type| TYPES.key?(type) }
        raise RuntimeError, "unknown C ABI type #{bad.first.inspect}" unless bad.empty?
        raise RuntimeError, 'void is only valid as a return type' if @params.include?('void')
        address = handle[@name]
        @function = Fiddle::Function.new(address, @params.map { |t| TYPES.fetch(t) }, TYPES.fetch(@result))
      rescue Fiddle::DLError => e
        raise RuntimeError, "C symbol #{@name.inspect}: #{e.message}"
      end

      def call(*args)
        raise RuntimeError, "#{@name} expects #{@params.length} arguments, got #{args.length}" unless args.length == @params.length
        marshaled = args.zip(@params).map { |value, type| marshal_arg(value, type) }
        convert_result(@function.call(*marshaled))
      rescue Fiddle::DLError, TypeError, ArgumentError => e
        raise RuntimeError, "C call #{@name}: #{e.message}"
      end

      def to_s = "cfn<#{@name}(#{@params.join(',')}) -> #{@result}>"
      def inspect = to_s

      private

      def marshal_arg(value, type)
        case type
        when 'cstr' then value.to_s
        when 'ptr'
          case value
          when nil then 0
          when NativePointerValue then value.pointer
          when CBufferValue then value.pointer
          when Fiddle::Pointer then value
          when Integer then value
          else raise RuntimeError, "#{@name}: ptr argument requires cbuf/ptr/int/void"
          end
        when 'f32', 'f64' then Float(value)
        when 'bool' then value ? 1 : 0
        else Integer(value)
        end
      end

      def convert_result(value)
        case @result
        when 'void' then nil
        when 'bool' then value != 0 && value != false
        when 'cstr'
          return nil if value.nil? || (value.respond_to?(:to_i) && value.to_i.zero?)
          value.is_a?(Fiddle::Pointer) ? value.to_s : Fiddle::Pointer.new(value.to_i).to_s
        when 'ptr'
          NativePointerValue.new(value || 0)
        else value
        end
      end
    end

    class CommandValue
      attr_reader :argv
      def initialize(argv)
        @argv = argv.map(&:to_s).freeze
        raise RuntimeError, 'cmd() requires at least one argv item' if @argv.empty? || @argv[0].empty?
      end
      def to_s = "cmd<#{@argv.map(&:inspect).join(' ')}>"
      def inspect = to_s
    end

    class NamespaceValue
      attr_reader :name, :members

      def initialize(name)
        @name = name.to_s.freeze
        @members = {}
      end

      def member?(name) = @members.key?(name.to_s)
      def get(name) = @members[name.to_s]
      def set(name, value) = (@members[name.to_s] = value)
      def keys = @members.keys.sort
      def to_s = "space<#{@name}>"
      def inspect = to_s
    end

    class NativeLibraryValue < NamespaceValue
      attr_reader :path, :handle
      def initialize(name, path)
        super(name)
        @path = path.to_s.freeze
        @handle = %w[@self self process].include?(@path) ? Fiddle::Handle::DEFAULT : Fiddle::Handle.new(@path)
      rescue Fiddle::DLError => e
        raise RuntimeError, "cannot load C library #{@path.inspect}: #{e.message}"
      end
      def to_s = "bridge<#{name}:#{@path}>"
      def inspect = to_s
    end


    class ObjectValue
      attr_reader :proto_name

      def initialize(proto_name, fields = {})
        @proto_name = proto_name.to_s.freeze
        @fields = fields.dup
        @lock = Mutex.new
      end

      def field?(name)
        key = name.to_s
        @lock.synchronize { @fields.key?(key) }
      end

      def get(name)
        key = name.to_s
        @lock.synchronize { @fields[key] }
      end

      def set(name, value)
        key = name.to_s
        @lock.synchronize { @fields[key] = value }
        value
      end

      def update(name)
        key = name.to_s
        @lock.synchronize do
          @fields[key] = yield(@fields[key])
        end
      end

      def fields
        @lock.synchronize { @fields.dup }
      end

      def copy
        self.class.new(@proto_name, fields)
      end

      def to_s
        body = fields.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')
        "#{@proto_name}{#{body}}"
      end

      def inspect = to_s
    end

    class TaskValue
      def initialize(&work)
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @state = :pending
        @value = nil
        @error = nil
        @thread = Thread.new do
          begin
            cancelled = @mutex.synchronize do
              if @state == :cancelled
                true
              else
                @state = :running
                false
              end
            end
            next if cancelled

            value = work.call
            @mutex.synchronize do
              unless @state == :cancelled
                @value = value
                @state = :done
              end
              @cv.broadcast
            end
          rescue Exception => e # task boundary: preserve error for await()
            @mutex.synchronize do
              unless @state == :cancelled
                @error = e
                @state = :failed
              end
              @cv.broadcast
            end
          end
        end
      end

      def await(timeout = nil)
        timeout = timeout&.to_f
        deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil
        @mutex.synchronize do
          until %i[done failed cancelled].include?(@state)
            if deadline
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise RuntimeError, 'task await timed out' if remaining <= 0
              @cv.wait(@mutex, remaining)
            else
              @cv.wait(@mutex)
            end
          end
          raise RuntimeError, "task cancelled" if @state == :cancelled
          if @error
            raise @error if @error.is_a?(Srsh::Error)
            raise RuntimeError, "task failed: #{@error.class}: #{@error.message}"
          end
          @value
        end
      end

      def done?
        @mutex.synchronize { %i[done failed cancelled].include?(@state) }
      end

      def status
        @mutex.synchronize { @state.to_s }
      end

      def cancel
        thread = nil
        @mutex.synchronize do
          return false if %i[done failed cancelled].include?(@state)
          @state = :cancelled
          thread = @thread
          @cv.broadcast
        end
        thread.kill if thread&.alive?
        true
      end

      def thread = @thread
      def to_s = "task<#{status}>"
      def inspect = to_s
    end

    class ChannelValue
      CLOSED = Object.new.freeze

      def initialize(capacity = 0)
        capacity = capacity.to_i
        raise RuntimeError, 'channel capacity cannot be negative' if capacity.negative?
        @capacity = capacity
        @queue = []
        @closed = false
        @mutex = Mutex.new
        @readable = ConditionVariable.new
        @writable = ConditionVariable.new
      end

      def send_value(value)
        @mutex.synchronize do
          raise RuntimeError, 'send on closed channel' if @closed
          while @capacity.positive? && @queue.length >= @capacity
            @writable.wait(@mutex)
            raise RuntimeError, 'send on closed channel' if @closed
          end
          @queue << value
          @readable.signal
        end
        value
      end

      def recv(timeout = nil)
        timeout = timeout&.to_f
        deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil
        @mutex.synchronize do
          while @queue.empty? && !@closed
            if deadline
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              raise RuntimeError, 'channel receive timed out' if remaining <= 0
              @readable.wait(@mutex, remaining)
            else
              @readable.wait(@mutex)
            end
          end
          return nil if @queue.empty? && @closed
          value = @queue.shift
          @writable.signal
          value
        end
      end

      def try_recv
        @mutex.synchronize do
          return nil if @queue.empty?
          value = @queue.shift
          @writable.signal
          value
        end
      end

      def close
        @mutex.synchronize do
          return false if @closed
          @closed = true
          @readable.broadcast
          @writable.broadcast
        end
        true
      end

      def closed? = @mutex.synchronize { @closed }
      def size = @mutex.synchronize { @queue.length }
      def to_s = "chan<#{size}#{closed? ? ',closed' : ''}>"
      def inspect = to_s
    end

    class AtomValue
      def initialize(value)
        @value = value
        @lock = Mutex.new
      end

      def get = @lock.synchronize { @value }

      def set(value)
        @lock.synchronize { @value = value }
        value
      end

      def swap
        @lock.synchronize { @value = yield(@value) }
      end

      def to_s = "atom<#{get.inspect}>"
      def inspect = to_s
    end
  end
end
