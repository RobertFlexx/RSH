require 'json'
require_relative 'security'

module Srsh
  class Theme
    MAX_THEME_BYTES = 256 * 1024
    ANSI_RE = /\A(?:\d{1,3})(?:;\d{1,3}){0,6}\z/

    DEFAULTS = {
      'classic' => {
        border: '1;35', title: '1;33', key: '1;36', value: '0;37',
        ok: '32', warn: '33', error: '31', dim: '90', path: '33', host: '36', mark: '35'
      },
      'mono' => {
        border: '1;37', title: '1;37', key: '0;37', value: '0;37',
        ok: '0;37', warn: '0;37', error: '0;37', dim: '90', path: '0;37', host: '0;37', mark: '0;37'
      },
      'neon' => {
        border: '1;35', title: '1;92', key: '1;95', value: '0;37',
        ok: '1;92', warn: '1;93', error: '1;91', dim: '90', path: '1;93', host: '1;96', mark: '1;95'
      },
      'ocean' => {
        border: '1;34', title: '1;96', key: '36', value: '0;37',
        ok: '1;92', warn: '1;93', error: '1;91', dim: '90', path: '34', host: '96', mark: '36'
      }
    }.freeze

    attr_reader :name

    def initialize(paths, state)
      @paths = paths
      @state = state
      @themes = DEFAULTS.transform_values(&:dup)
      load_user_themes
      @base_themes = @themes.transform_values(&:dup).freeze
      wanted = ENV['SRSH_THEME'].to_s.strip
      wanted = File.read(paths.theme_state).strip if wanted.empty? && File.file?(paths.theme_state)
      use(wanted.empty? ? 'classic' : wanted)
    end

    def names = @themes.keys.sort

    def reset_dynamic!
      current = @name
      @themes = @base_themes.transform_values(&:dup)
      use(@themes.key?(current) ? current : 'classic')
    end

    def register(name, values)
      clean = {}
      values.each do |key, value|
        value = value.to_s
        clean[key.to_sym] = value if value.match?(ANSI_RE)
      end
      @themes[name.to_s] = @themes['classic'].merge(clean) unless clean.empty?
    end

    def use(name)
      return false unless @themes.key?(name)
      @name = name
      @state.theme_name = name
      Security.atomic_write(@paths.theme_state, "#{name}\n") rescue nil
      true
    end

    def code(key) = @themes.fetch(@name, @themes['classic'])[key.to_sym]

    def paint(text, key, io: STDOUT)
      code = code(key)
      color_ok = io.respond_to?(:tty?) && io.tty?
      return text.to_s if !color_ok || code.nil?
      "\e[#{code}m#{text}\e[0m"
    end

    private

    def load_user_themes
      Dir.glob(File.join(@paths.themes, '*.{theme,json}')).sort.each do |path|
        next unless Security.private_regular_file?(path)
        next if File.size(path) > MAX_THEME_BYTES
        raw = File.extname(path) == '.json' ? JSON.parse(File.binread(path, MAX_THEME_BYTES + 1)) : parse_kv(path)
        next unless raw.is_a?(Hash)
        clean = {}
        raw.each do |key, value|
          value = value.to_s
          clean[key.to_sym] = value if value.match?(ANSI_RE)
        end
        next if clean.empty?
        @themes[File.basename(path, '.*')] = @themes['classic'].merge(clean)
      rescue JSON::ParserError, SystemCallError
        next
      end
    end

    def parse_kv(path)
      data = File.binread(path, MAX_THEME_BYTES + 1)
      return {} if data.bytesize > MAX_THEME_BYTES
      data.force_encoding(Encoding::UTF_8)
      return {} unless data.valid_encoding?
      data.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        key, value = line.split('=', 2)
        [key&.strip, value&.strip] if key && value
      end.to_h
    end
  end
end
