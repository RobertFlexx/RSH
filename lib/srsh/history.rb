require_relative 'security'

module Srsh
  class History
    include Enumerable
    DEFAULT_MAX = 5000

    def initialize(path, import_paths: [])
      @path = path
      @import_paths = Array(import_paths).reject { |p| p == path }.uniq
      @max = Integer(ENV.fetch('SRSH_HISTORY_MAX', DEFAULT_MAX), exception: false) || DEFAULT_MAX
      @max = DEFAULT_MAX unless @max.positive?
      @items = []
      load_path(path)
      @import_paths.each { |other| load_path(other, promote_duplicates: true) }
      trim!
      @dirty = @import_paths.any? { |p| File.file?(p) }
    rescue SystemCallError, ArgumentError
      @items ||= []
      @dirty = false
    end

    def each(&block) = @items.each(&block)
    def length = @items.length
    def [](index) = @items[index]
    def reverse_each(&block) = @items.reverse_each(&block)

    def add(line)
      line = line.to_s
      return if line.empty? || @items.last == line
      @items << line
      trim!
      @dirty = true
    end

    def clear
      @items.clear
      @dirty = true
      flush
      @import_paths.each do |path|
        Security.atomic_write(path, '') if File.file?(path)
      rescue SystemCallError
        next
      end
    end

    def flush
      return unless @dirty
      Security.atomic_write(@path, @items.join("\n") + (@items.empty? ? '' : "\n"))
      @dirty = false
    end

    private

    def load_path(path, promote_duplicates: false)
      return unless File.file?(path)
      File.foreach(path, chomp: true) do |line|
        next if line.empty?
        @items.delete(line) if promote_duplicates
        @items << line
        # Keep startup memory bounded even if a corrupted/ancient history file
        # contains millions of lines. Trim in batches to avoid O(n^2) shifting.
        @items = @items.last(@max) if @items.length > (@max * 2)
      end
    rescue SystemCallError
      nil
    end

    def trim!
      extra = @items.length - @max
      @items.shift(extra) if extra.positive?
    end
  end
end
