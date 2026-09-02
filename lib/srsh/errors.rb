module Srsh
  class Error < StandardError; end
  class ParseError < Error
    attr_reader :line, :column
    def initialize(message, line: nil, column: nil)
      @line = line
      @column = column
      where = line ? " at #{line}:#{column || 1}" : ''
      super("#{message}#{where}")
    end
  end
  # ParseError means the input is wrong. IncompleteInput is the useful
  # subset: the parser reached the end while it was still waiting for input.
  # The interactive shell uses this to decide whether to show the `...` prompt.
  class IncompleteInput < ParseError; end
  class RuntimeError < Error; end
  class BreakSignal < Exception; end
  class NextSignal < Exception; end
  class ReturnSignal < Exception
    attr_reader :value
    def initialize(value = nil) = (@value = value)
  end
end
