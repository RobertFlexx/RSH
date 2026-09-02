require 'socket'
require_relative 'version'
require_relative 'paths'
require_relative 'state'
require_relative 'theme'
require_relative 'history'
require_relative 'security'
require_relative 'plugins'
require_relative 'builtins'
require_relative 'editor'
require_relative 'language/parser'
require_relative 'shell/executor'
require_relative 'shell/lexer'

module Srsh
  class App
    attr_reader :paths, :state, :theme, :history, :plugins, :builtins, :executor
    attr_accessor :out, :err

    def initialize(out: STDOUT, err: STDERR, home: Dir.home)
      @out = out
      @err = err
      @paths = Paths.new(home).ensure!
      @state = State.new
      @theme = Theme.new(paths, state)
      @history = History.new(paths.history, import_paths: [paths.history_v1])
      @builtins = Builtins.new(self)
      @executor = Shell::Executor.new(self)
      @plugins = Plugins.new(self)
      @editor = Editor.new(self)
      @loaded_startup = false
      @skip_startup = false
      install_signals
    end

    def disable_startup!
      @skip_startup = true
      self
    end

    def startup!
      return if @loaded_startup
      if @skip_startup
        @loaded_startup = true
        return
      end
      create_default_rc
      load_rc
      plugins.load_all
      @loaded_startup = true
    end

    def reload!
      @state.functions.clear
      @state.prototypes.clear
      @state.traits.clear
      @state.aliases.clear
      @state.clear_hooks!
      @builtins.reset_dynamic!
      @theme.reset_dynamic!
      load_rc
      plugins.load_all
    end

    def run_script(path, argv = [])
      real = File.expand_path(path)
      raise Error, "script not found: #{path}" unless File.file?(real)
      raise Error, 'script too large' if File.size(real) > 4 * 1024 * 1024
      text = read_script_limited(real)
      nodes = Language::ProgramParser.new(text).parse
      scope = { '$0' => real }
      argv.each_with_index { |value, i| scope["$#{i + 1}"] = value }
      @state.push_scope(scope)
      executor.run_program(nodes)
    ensure
      @state.pop_scope if defined?(scope) && scope
    end

    def check_script(path)
      real = File.expand_path(path)
      raise Error, "script not found: #{path}" unless File.file?(real)
      Language::ProgramParser.new(read_script_limited(real)).parse
      out.puts "#{path}: syntax ok"
      0
    rescue StandardError => e
      err.puts "#{path}: #{e.message}"
      2
    end

    def run_command(command)
      startup!
      executor.execute_line(command)
    end

    def run_expression(source)
      startup!
      raise ParseError, 'expression cannot contain a newline' if source.to_s.include?("\n")
      nodes = Language::ProgramParser.new("= #{source}\n").parse
      executor.run_program(nodes)
    end

    def run_input(input)
      text = input.to_s
      if rsh_candidate?(text)
        executor.run_program(Language::ProgramParser.new(text.end_with?("\n") ? text : text + "\n").parse)
      else
        executor.execute_line(text)
      end
    end

    def interactive
      startup!
      welcome
      hostname = Socket.gethostname.split('.').first
      loop do
        state.prune_jobs!
        title
        input = @editor.read(prompt(hostname))
        break if input == :eof
        next if input == :interrupt
        next if input.nil? || input.strip.empty?
        record_history(input)
        begin
          input = collect_incomplete_input(input)
          break if input == :eof
          next if input == :interrupt
          run_input(input)
        rescue BreakSignal, NextSignal, ReturnSignal
          err.puts theme.paint('control-flow marker used outside a script/function', :error, io: err)
          state.last_status = 2
        rescue StandardError => e
          err.puts theme.paint("srsh: #{e.class}: #{e.message}", :error, io: err)
          state.last_status = 1
        end
      end
      0
    ensure
      history.flush
    end

    def prompt(hostname)
      "#{theme.paint(short_pwd, :path, io: out)} #{theme.paint(hostname, :host, io: out)}#{theme.paint(' > ', :mark, io: out)}"
    end

    private

    def rsh_candidate?(text)
      line = text.to_s.lstrip
      return true if line.match?(/\A(?:=\s+|emit\s+|return(?:\s|$)|break$|continue$|\^|\?|@|::)/)
      return true if line.match?(/\A(?:try|if|each|while|fn|task|match|code|use|defer|bridge|space|proto|trait|slot)\b/)
      return true if line.include?('|>')
      return true if line.match?(/\A(?:\*?[A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*\*?[A-Za-z_][A-Za-z0-9_]*)+|\$?[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*(?::=|\+=|-=|\*=|\/=|%=|\+\+=)/)
      return true if line.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*\(/)
      false
    end

    def collect_incomplete_input(first)
      text = first.to_s
      loop do
        return text unless incomplete_input?(text)
        more = @editor.read(theme.paint('... ', :dim, io: out))
        return more if more == :eof || more == :interrupt
        more = more.to_s
        record_history(more)
        text << "\n" << more
      end
    end

    # History is line-oriented on disk and ghost completion is line-oriented in
    # the editor.  A bracketed multi-line paste therefore records its physical
    # lines just like manually entering a continued block instead of stuffing a
    # newline-bearing pseudo-entry into history.
    def record_history(text)
      text.to_s.each_line do |line|
        line = line.chomp
        history.add(line) unless line.strip.empty?
      end
    end

    def incomplete_input?(text)
      if rsh_candidate?(text)
        begin
          Language::ProgramParser.new(text.end_with?("\n") ? text : text + "\n").parse
          false
        rescue IncompleteInput
          true
        rescue ParseError
          false
        end
      else
        begin
          tokens = Shell::Lexer.scan(text)
          last = tokens.last
          last && last.type == :op && %w[| && || < > >> 2> 2>>].include?(last.text)
        rescue IncompleteInput
          true
        rescue ParseError
          false
        end
      end
    end

    def short_pwd
      home = paths.home
      pwd = Dir.pwd
      pwd.start_with?(home) ? pwd.sub(home, '~') : pwd
    end

    def title
      return unless out.respond_to?(:tty?) && out.tty?
      out.print "\e]0;srsh #{VERSION}: #{Dir.pwd}\a"
    end

    def welcome
      out.puts theme.paint("Simple Ruby Shell #{VERSION}", :title, io: out)
      out.puts theme.paint("Ruby #{RUBY_VERSION} · #{RUBY_PLATFORM}", :dim, io: out)
      out.puts "type #{theme.paint('help', :key, io: out)} for commands; RSH hot forms work here too\n\n"
    end

    def load_rc
      return unless File.file?(paths.rc)
      unless Security.private_regular_file?(paths.rc)
        err.puts theme.paint("srsh: refusing unsafe rc file #{paths.rc}", :warn, io: err)
        return
      end
      run_script(paths.rc, [])
    rescue StandardError => e
      err.puts theme.paint("srshrc: #{e.class}: #{e.message}", :error, io: err)
    end

    def create_default_rc
      return if File.exist?(paths.rc)
      Security.atomic_write(paths.rc, <<~RSH)
        # ~/.srshrc: Simple Ruby Shell startup script
        #
        # alias ll=ls -lah
        # $EDITOR := "nano"
        # scheme ocean
      RSH
    rescue SystemCallError
    end

    def read_script_limited(path)
      limit = 4 * 1024 * 1024
      File.open(path, 'rb') do |io|
        data = io.read(limit + 1) || ''.b
        raise Error, 'script too large' if data.bytesize > limit
        data.force_encoding(Encoding::UTF_8)
        raise Error, 'script is not valid UTF-8' unless data.valid_encoding?
        data
      end
    end

    def install_signals
      Signal.trap('INT', 'IGNORE')
      Signal.trap('TTOU', 'IGNORE') if Signal.list.key?('TTOU')
      Signal.trap('TTIN', 'IGNORE') if Signal.list.key?('TTIN')
      Signal.trap('TSTP', 'IGNORE') if Signal.list.key?('TSTP')
    end
  end
end
