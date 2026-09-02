require 'fileutils'
require 'socket'
require 'etc'
require 'rbconfig'
require 'io/console'

module Srsh
  class Builtins
    def initialize(app)
      @app = app
      @table = {}
      @dir_stack = []
      install
      @core_table = @table.dup.freeze
    end

    def register(name, &block) = @table[name.to_s] = block
    def key?(name) = @table.key?(name.to_s)
    def names = @table.keys
    def reset_dynamic! = @table = @core_table.dup
    def call(name, args) = @table.fetch(name).call(args)

    private

    def install
      register('cd') { |a| cd(a) }
      register('pwd') { |_a| @app.out.puts @app.theme.paint(Dir.pwd, :key, io: @app.out); 0 }
      register('put') { |a| @app.out.puts(a[1..].join(' ')); 0 }
      register('ls') { |a| ls_builtin(a) }
      register('echo') { |a| @app.out.puts(a[1..].join(' ')); 0 }
      register('printf') { |a| printf_builtin(a) }
      register('alias') { |a| alias_builtin(a) }
      register('unalias') { |a| unalias_builtin(a) }
      register('set') { |a| set_builtin(a) }
      register('export') { |a| export_builtin(a) }
      register('option') { |a| option_builtin(a) }
      register('unset') { |a| ENV.delete(a[1].to_s); a[1] ? 0 : 2 }
      register('read') { |a| read_builtin(a) }
      register('true') { |_a| 0 }
      register('false') { |_a| 1 }
      register('sleep') { |a| Kernel.sleep(Float(a[1] || 1)); 0 }
      register('source') { |a| source_builtin(a) }
      register('.') { |a| source_builtin(a) }
      register('exit') { |a| exit(Integer(a[1] || 0)) }
      register('quit') { |a| exit(Integer(a[1] || 0)) }
      register('help') { |_a| help; 0 }
      register('hist') { |_a| history; 0 }
      register('clearhist') { |_a| @app.history.clear; 0 }
      register('scheme') { |a| scheme(a) }
      register('theme') { |a| scheme(a) }
      register('themes') { |_a| scheme(['scheme', '--list']) }
      register('plugins') { |_a| plugins; 0 }
      register('reload') { |_a| @app.reload!; 0 }
      register('jobs') { |_a| jobs; 0 }
      register('wait') { |a| @app.executor.wait_job(a[1]) }
      register('fg') { |a| @app.executor.foreground_job(a[1]) }
      register('bg') { |a| @app.executor.background_job(a[1]) }
      register('exec') { |a| exec_builtin(a) }
      register('systemfetch') { |_a| systemfetch; 0 }
      register('which') { |a| which(a) }
      register('type') { |a| which(a) }
      register('dirs') { |_a| dirs_builtin }
      register('pushd') { |a| pushd_builtin(a) }
      register('popd') { |_a| popd_builtin }
      register('umask') { |a| umask_builtin(a) }
      register('kill') { |a| kill_builtin(a) }
    end


    def exec_builtin(args)
      if args.length < 2
        @app.err.puts 'exec: usage: exec COMMAND [ARG ...]'
        return 2
      end
      path = @app.executor.find_executable(args[1])
      unless path
        @app.err.puts "exec: command not found: #{args[1]}"
        return 127
      end
      Kernel.exec(path, *args[2..])
    rescue SystemCallError => e
      @app.err.puts "exec: #{e.message}"
      126
    end

    def ls_builtin(args)
      # Preserve the original SRSH pretty `ls` for the simple form, but hand
      # option-heavy invocations to the system ls so normal Unix muscle memory
      # still works.
      if args.length > 2 || args[1].to_s.start_with?('-')
        @app.err.puts 'ls: external ls not found'
        return 127
      end

      dir = args[1] || '.'
      entries = Dir.children(dir).sort
      labels = entries.map do |name|
        full = File.join(dir, name)
        if File.directory?(full)
          @app.theme.paint("#{name}/", :key, io: @app.out)
        elsif File.executable?(full)
          @app.theme.paint("#{name}*", :ok, io: @app.out)
        else
          name
        end
      end
      print_columns(labels)
      0
    rescue SystemCallError => e
      @app.err.puts "ls: #{e.message}"
      1
    end

    def print_columns(labels)
      return if labels.empty?
      width = begin
        IO.console&.winsize&.[](1)
      rescue IOError, SystemCallError
        nil
      end
      width = 80 unless width && width.positive?
      plain = ->(x) { x.gsub(/\e\[[0-9;]*m/, '') }
      max = labels.map { |x| plain.call(x).length }.max || 0
      col_width = [max + 2, 4].max
      cols = [width / col_width, 1].max
      rows = (labels.length.to_f / cols).ceil
      rows.times do |row|
        line = +''
        cols.times do |col|
          idx = col * rows + row
          break if idx >= labels.length
          label = labels[idx]
          line << label << (' ' * [col_width - plain.call(label).length, 0].max)
        end
        @app.out.puts line.rstrip
      end
    end

    def cd(args)
      target = args[1] || ENV['HOME'] || Dir.home
      old = Dir.pwd
      Dir.chdir(File.expand_path(target))
      ENV['OLDPWD'] = old
      ENV['PWD'] = Dir.pwd
      0
    rescue SystemCallError => e
      @app.err.puts "cd: #{e.message}"
      1
    end

    def alias_builtin(args)
      if args.length == 1
        @app.state.aliases.sort.each { |k, v| @app.out.puts "#{k}=#{v.inspect}" }
        return 0
      end
      text = args[1..].join(' ')
      name, value = text.split('=', 2)
      if name.nil? || value.nil? || !name.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/)
        @app.err.puts 'alias: use alias name=command'
        return 2
      end
      @app.state.aliases[name] = value
      0
    end

    def unalias_builtin(args)
      return 2 unless args[1]
      @app.state.aliases.delete(args[1])
      0
    end

    def set_builtin(args)
      if args.length == 1
        ENV.keys.sort.each { |k| @app.out.puts "#{k}=#{ENV[k]}" }
      else
        ENV[args[1]] = args[2..].join(' ')
      end
      0
    end

    def printf_builtin(args)
      return 0 if args.length == 1
      format = args[1].to_s
      values = args[2..] || []
      # Shell printf is intentionally permissive. Convert obvious numerics but
      # leave everything else alone so %s never surprises you.
      cooked = values.map do |value|
        if value.match?(/\A[-+]?\d+\z/)
          value.to_i
        elsif value.match?(/\A[-+]?(?:\d+\.\d*|\d*\.\d+)(?:[eE][-+]?\d+)?\z/)
          value.to_f
        else
          value
        end
      end
      @app.out.print(format % cooked)
      0
    rescue ArgumentError => e
      @app.err.puts "printf: #{e.message}"
      2
    end

    def export_builtin(args)
      if args.length == 1
        ENV.keys.sort.each { |key| @app.out.puts "export #{key}=#{ENV[key].inspect}" }
        return 0
      end
      status = 0
      args[1..].each do |item|
        name, value = item.split('=', 2)
        unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          @app.err.puts "export: bad name #{name.inspect}"
          status = 2
          next
        end
        ENV[name] = value.nil? ? ENV[name].to_s : value
      end
      status
    end

    def option_builtin(args)
      opts = @app.state.options
      if args.length == 1
        opts.keys.sort.each { |name| @app.out.puts "#{name}=#{opts[name] ? 'yes' : 'no'}" }
        return 0
      end
      name = args[1].to_s
      value = args[2]
      if name == 'strict'
        enabled = parse_toggle(value.nil? ? 'yes' : value)
        opts['pipefail'] = enabled
        opts['nounset'] = enabled
        return 0
      end
      unless opts.key?(name)
        @app.err.puts "option: unknown option #{name.inspect}"
        return 2
      end
      if value.nil?
        @app.out.puts "#{name}=#{opts[name] ? 'yes' : 'no'}"
      else
        opts[name] = parse_toggle(value)
      end
      0
    rescue ArgumentError => e
      @app.err.puts "option: #{e.message}"
      2
    end

    def parse_toggle(value)
      case value.to_s.downcase
      when 'yes', 'on', 'true', '1' then true
      when 'no', 'off', 'false', '0' then false
      else raise ArgumentError, "expected yes/no, got #{value.inspect}"
      end
    end

    def dirs_builtin
      @app.out.puts ([Dir.pwd] + @dir_stack.reverse).join(' ')
      0
    end

    def pushd_builtin(args)
      target = args[1] || @dir_stack.last
      unless target
        @app.err.puts 'pushd: no other directory'
        return 1
      end
      old = Dir.pwd
      Dir.chdir(File.expand_path(target))
      @dir_stack << old
      ENV['OLDPWD'] = old
      ENV['PWD'] = Dir.pwd
      dirs_builtin
    rescue SystemCallError => e
      @app.err.puts "pushd: #{e.message}"
      1
    end

    def popd_builtin
      target = @dir_stack.pop
      unless target
        @app.err.puts 'popd: directory stack empty'
        return 1
      end
      old = Dir.pwd
      Dir.chdir(target)
      ENV['OLDPWD'] = old
      ENV['PWD'] = Dir.pwd
      dirs_builtin
    rescue SystemCallError => e
      @app.err.puts "popd: #{e.message}"
      1
    end

    def umask_builtin(args)
      if args[1].nil?
        old = Process.umask
        Process.umask(old)
        @app.out.printf "%04o\n", old
        return 0
      end
      text = args[1].to_s
      raise ArgumentError, 'mask must be octal' unless text.match?(/\A[0-7]{1,4}\z/)
      Process.umask(text.to_i(8))
      0
    rescue ArgumentError => e
      @app.err.puts "umask: #{e.message}"
      2
    end

    def kill_builtin(args)
      return 2 if args.length < 2
      signal = 'TERM'
      rest = args[1..]
      if rest[0].start_with?('-')
        signal = rest.shift.delete_prefix('-')
        signal = signal.to_i if signal.match?(/\A\d+\z/)
      end
      status = 0
      rest.each do |pid_text|
        begin
          Process.kill(signal, Integer(pid_text))
        rescue SystemCallError, ArgumentError => e
          @app.err.puts "kill: #{pid_text}: #{e.message}"
          status = 1
        end
      end
      status
    end

    def read_builtin(args)
      return 2 unless args[1]
      ENV[args[1]] = ($stdin.gets || '').chomp
      0
    end

    def source_builtin(args)
      return 2 unless args[1]
      @app.run_script(args[1], args[2..] || [])
      @app.state.last_status
    rescue StandardError => e
      @app.err.puts "source: #{e.message}"
      1
    end

    def help
      @app.out.puts @app.theme.paint("srsh #{Srsh::VERSION}: Simple Ruby Shell", :title, io: @app.out)
      @app.out.puts <<~TXT

        shell:       cd pwd ls printf alias unalias set export unset read source
                     jobs wait fg bg exec which/type pushd popd dirs umask kill
        shell opts:  option pipefail|nounset|noclobber yes|no
                     option strict yes|no
        info:        systemfetch hist clearhist scheme/theme themes plugins reload help

        RSH values:  name := EXPR             local binding
                     $NAME := EXPR            process environment
                     = EXPR                   print a value
                     value |> fn              value pipeline
                     $(command)               process output -> value

        flow:        if / each / while / match / try
                     ? / @ / @? / ??          short forms
                     fn name(args)            function
                     ::x => EXPR              lambda
                     return / break / continue

        structure:   space name ... end       namespace
                     use "file.rsh" as name  module namespace
                     defer statement          LIFO cleanup
                     proto / trait / slot     objects + composition
                     code name ... end        parsed code value

        concurrency: task work(args)          async function
                     &:: => EXPR              spawn now
                     await / await_all / race
                     chan / atom / parallel / pmap

        processes:   cmd("prog", arg...)      argv-safe command value
                     .result .capture .check .task

        native C:    bridge c from "lib.so"
                       symbol(cstr, usize) -> i32
                     end
                     cbuf(size)                bounded writable memory

        functional:  map filter reject fold find any all count sum sort uniq
                     flat zip enumerate take drop chunk group each tap
                     partial compose

        Values include lists, %[maps], ranges, interpolated "\#{...}", yes/no/void,
        safe ?. / ?[] access, first-class functions/tasks/code/prototypes, and C
        bridge values. `|` is a Unix process pipe; `|>` is an RSH value pipe.
      TXT
    end

    def history
      @app.history.each.with_index(1) { |line, i| @app.out.printf("%5d  %s\n", i, line) }
    end

    def scheme(args)
      if args[1].nil?
        @app.out.puts @app.theme.name
        return 0
      end
      if %w[-l --list].include?(args[1])
        @app.out.puts @app.theme.names.join("\n")
        return 0
      end
      return 0 if @app.theme.use(args[1])
      @app.err.puts "scheme: unknown theme #{args[1].inspect}"
      1
    end

    def plugins
      @app.plugins.loaded.each { |p| @app.out.puts File.basename(p) }
      0
    end

    def jobs
      @app.state.prune_jobs!
      @app.state.jobs.each do |job|
        @app.out.puts "[#{job.id}] #{job.status.to_s.ljust(8)} #{job.command}"
        job.notified = true if job.done?
      end
      0
    end

    def which(args)
      if args.length < 2
        @app.err.puts 'which: usage: which NAME [...]'
        return 2
      end
      status = 0
      args[1..].each do |name|
        if key?(name)
          @app.out.puts "#{name}: srsh builtin"
        elsif @app.state.functions.key?(name)
          kind = @app.state.functions[name].is_a?(Srsh::Language::TaskFunctionNode) ? 'task function' : 'function'
          @app.out.puts "#{name}: srsh #{kind}"
        elsif @app.state.prototypes.key?(name)
          @app.out.puts "#{name}: srsh prototype"
        elsif @app.state.traits.key?(name)
          @app.out.puts "#{name}: srsh trait"
        elsif (path = @app.executor.find_executable(name))
          @app.out.puts path
        else
          @app.err.puts "#{name}: not found"
          status = 1
        end
      end
      status
    end

    def systemfetch
      host = Socket.gethostname
      user = ENV['USER'] || Etc.getlogin || Etc.getpwuid.name rescue 'unknown'
      os = if File.file?('/etc/os-release')
             match = File.read('/etc/os-release').match(/^PRETTY_NAME=(?:"(.*)"|(.*))$/)
             match ? (match[1] || match[2]) : RbConfig::CONFIG['host_os']
           else
             RbConfig::CONFIG['host_os']
           end
      mem = if File.file?('/proc/meminfo')
              info = File.read('/proc/meminfo').scan(/^(\w+):\s+(\d+)/).to_h.transform_values { |v| v.to_i * 1024 }
              total = info['MemTotal'].to_i
              avail = info['MemAvailable'].to_i
              total.positive? ? "#{human(total - avail)} / #{human(total)}" : 'n/a'
            else
              'n/a'
            end
      @app.out.puts @app.theme.paint("#{user}@#{host}", :title, io: @app.out)
      @app.out.puts "OS:    #{os}"
      @app.out.puts "Shell: srsh #{Srsh::VERSION}"
      @app.out.puts "Ruby:  #{RUBY_ENGINE} #{RUBY_VERSION}"
      @app.out.puts "RAM:   #{mem}"
      0
    end

    def human(bytes)
      units = %w[B KiB MiB GiB TiB]
      value = bytes.to_f
      unit = units.shift
      while value >= 1024 && !units.empty?
        value /= 1024
        unit = units.shift
      end
      format('%.1f %s', value, unit)
    end
  end
end
