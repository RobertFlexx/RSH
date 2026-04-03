#!/usr/bin/env ruby
require 'shellwords'
require 'socket'
require 'time'
require 'etc'
require 'rbconfig'
require 'io/console'
require 'fileutils'
require 'json'

SRSH_VERSION = "0.8.0"

$0 = "srsh-#{SRSH_VERSION}"
ENV['SHELL'] = "srsh-#{SRSH_VERSION}"
print "\033]0;srsh-#{SRSH_VERSION}\007"

Dir.chdir(ENV['HOME']) if ENV['HOME']

SRSH_DIR        = File.join(Dir.home, ".srsh")
SRSH_PLUGINS_DIR= File.join(SRSH_DIR, "plugins")
SRSH_THEMES_DIR = File.join(SRSH_DIR, "themes")
SRSH_CONFIG     = File.join(SRSH_DIR, "config")
HISTORY_FILE    = File.join(Dir.home, ".srsh_history")
RC_FILE         = File.join(Dir.home, ".srshrc")
THEME_STATE_FILE= File.join(SRSH_DIR, "theme")

begin
  FileUtils.mkdir_p(SRSH_PLUGINS_DIR)
  FileUtils.mkdir_p(SRSH_THEMES_DIR)
rescue
end

$child_pids       = []
$aliases          = {}
$last_render_rows = 0
$last_status      = 0

$rsh_functions    = {}
$rsh_positional   = {}
$rsh_call_depth   = 0

$builtins         = {}
$hooks            = Hash.new { |h,k| h[k] = [] }

Signal.trap("INT", "IGNORE")

class RshBreak    < StandardError; end
class RshContinue < StandardError; end
class RshReturn   < StandardError; end

def read_kv_file(path)
  h = {}
  return h unless File.exist?(path)
  File.foreach(path) do |line|
    line = line.to_s.strip
    next if line.empty? || line.start_with?("#")
    k, v = line.split("=", 2)
    next if k.nil? || v.nil?
    h[k.strip] = v.strip
  end
  h
rescue
  {}
end

def write_kv_file(path, h)
  dir = File.dirname(path)
  FileUtils.mkdir_p(dir) rescue nil
  tmp = path + ".tmp"
  File.open(tmp, "w") do |f|
    h.keys.sort.each { |k| f.puts("#{k}=#{h[k]}") }
  end
  File.rename(tmp, path)
rescue
  nil
end

def supports_truecolor?
  ct = (ENV['COLORTERM'] || "").downcase
  return true if ct.include?("truecolor") || ct.include?("24bit")
  false
end

def term_colors
  @term_colors ||= begin
    out = `tput colors 2>/dev/null`.to_i
    out > 0 ? out : 8
  rescue
    8
  end
end

def fg_rgb(r,g,b)
  "38;2;#{r};#{g};#{b}"
end

def fg_256(n)
  "38;5;#{n}"
end

DEFAULT_THEMES = begin
  ghost = if supports_truecolor?
    fg_rgb(140,140,140)
  elsif term_colors >= 256
    fg_256(244)
  else
    "90"
  end

  {
    "classic" => {
      name: "classic",
      ui_border: "1;35",
      ui_title:  "1;33",
      ui_hdr:    "1;36",
      ui_key:    "1;36",
      ui_val:    "0;37",
      ok:        "32",
      warn:      "33",
      err:       "31",
      dim:       ghost,
      prompt_path: "33",
      prompt_host: "36",
      prompt_mark: "35",
      quote_rainbow: true,
    },

    "mono" => {
      name: "mono",
      ui_border: "1;37",
      ui_title:  "1;37",
      ui_hdr:    "0;37",
      ui_key:    "0;37",
      ui_val:    "0;37",
      ok:        "0;37",
      warn:      "0;37",
      err:       "0;37",
      dim:       ghost,
      prompt_path: "0;37",
      prompt_host: "0;37",
      prompt_mark: "0;37",
      quote_rainbow: false,
    },

    "neon" => {
      name: "neon",
      ui_border: "1;35",
      ui_title:  "1;92",
      ui_hdr:    "1;96",
      ui_key:    "1;95",
      ui_val:    "0;37",
      ok:        "1;92",
      warn:      "1;93",
      err:       "1;91",
      dim:       ghost,
      prompt_path: "1;93",
      prompt_host: "1;96",
      prompt_mark: "1;95",
      quote_rainbow: true,
    },

    "ocean" => begin
      deep = supports_truecolor? ? fg_rgb(0, 86, 180) : (term_colors >= 256 ? fg_256(25) : "34")
      light = supports_truecolor? ? fg_rgb(120, 210, 255) : (term_colors >= 256 ? fg_256(81) : "36")
      {
        name: "ocean",
        ui_border: deep,
        ui_title:  light,
        ui_hdr:    light,
        ui_key:    deep,
        ui_val:    "0;37",
        ok:        light,
        warn:      "33",
        err:       "31",
        dim:       ghost,
        prompt_path: deep,
        prompt_host: light,
        prompt_mark: light,
        quote_rainbow: false,
      }
    end,
  }
end

$themes = DEFAULT_THEMES.dup
$theme_name = nil
$theme = nil

def color(text, code)
  text = text.to_s
  return text if code.nil? || code.to_s.empty?
  "\e[#{code}m#{text}\e[0m"
end

def t(key)
  ($theme && $theme[key])
end

def ui(text, key)
  color(text, t(key))
end

def load_user_themes!
  Dir.glob(File.join(SRSH_THEMES_DIR, "*.theme")).each do |path|
    name = File.basename(path, ".theme")
    data = read_kv_file(path)
    next if data.empty?
    theme = { name: name.to_s }
    data.each do |k, v|
      theme[k.to_sym] = v
    end
    $themes[name] = theme
  end

  Dir.glob(File.join(SRSH_THEMES_DIR, "*.json")).each do |path|
    name = File.basename(path, ".json")
    begin
      obj = JSON.parse(File.read(path))
      next unless obj.is_a?(Hash)
      theme = { name: name.to_s }
      obj.each { |k,v| theme[k.to_sym] = v.to_s }
      $themes[name] = theme
    rescue
    end
  end
rescue
end

def set_theme!(name)
  name = name.to_s
  th = $themes[name]
  return false unless th.is_a?(Hash)
  $theme_name = name
  $theme = th
  begin
    File.write(THEME_STATE_FILE, name + "\n")
  rescue
  end
  true
end

def load_theme_state!
  load_user_themes!

  wanted = (ENV['SRSH_THEME'] || "").strip
  if wanted.empty? && File.exist?(THEME_STATE_FILE)
    wanted = File.read(THEME_STATE_FILE).to_s.strip
  end
  if wanted.empty?
    cfg = read_kv_file(SRSH_CONFIG)
    wanted = cfg['theme'].to_s.strip
  end

  wanted = "classic" if wanted.empty?
  set_theme!(wanted) || set_theme!("classic")
end

load_theme_state!

HISTORY_MAX = begin
  v = (ENV['SRSH_HISTORY_MAX'] || "5000").to_i
  v = 5000 if v <= 0
  v
end

HISTORY = if File.exist?(HISTORY_FILE)
  File.readlines(HISTORY_FILE, chomp: true).first(HISTORY_MAX)
else
  []
end

at_exit do
  begin
    trimmed = HISTORY.last(HISTORY_MAX)
    File.open(HISTORY_FILE, "w") { |f| trimmed.each { |line| f.puts(line) } }
  rescue
  end
end

begin
  unless File.exist?(RC_FILE)
    File.write(RC_FILE, <<~RC)
      # ~/.srshrc — srsh configuration (RSH)
      # Created automatically by srsh v#{SRSH_VERSION}
      #
      # Examples:
      #   alias ll='ls'
      #   scheme ocean
      #   set EDITOR nano
      #
      # Plugins:
      #   drop .rsh files into ~/.srsh/plugins/ to auto-load
      # Themes:
      #   drop .theme files into ~/.srsh/themes/ to add schemes
    RC
  end
rescue
end

def rainbow_codes
  [31, 33, 32, 36, 34, 35, 91, 93, 92, 96, 94, 95]
end

def human_bytes(bytes)
  units = ['B', 'KB', 'MB', 'GB', 'TB']
  size  = bytes.to_f
  unit  = units.shift
  while size > 1024 && !units.empty?
    size /= 1024
    unit  = units.shift
  end
  "#{format('%.2f', size)} #{unit}"
end

def nice_bar(p, w = 30, code = nil)
  p = [[p, 0.0].max, 1.0].min
  f = (p * w).round
  b = "█" * f + "░" * (w - f)
  pct = (p * 100).to_i
  bar = "[#{b}]"
  code ||= t(:ok)
  "#{color(bar, code)} #{color(sprintf("%3d%%", pct), t(:ui_val))}"
end

def terminal_width
  IO.console.winsize[1]
rescue
  80
end

def strip_ansi(str)
  str.to_s.gsub(/\e\[[0-9;]*m/, '')
end

CMD_SUBST_MAX = 256 * 1024

def expand_command_substitutions(str)
  return "" if str.nil?
  s = str.to_s.dup

  s.gsub(/\$\(([^()]*)\)/) do
    inner = $1.to_s.strip
    next "" if inner.empty?
    begin
      out = `#{inner} 2>/dev/null`
      out = out.to_s
      out = out.byteslice(0, CMD_SUBST_MAX) if out.bytesize > CMD_SUBST_MAX
      out.strip
    rescue
      ""
    end
  end
end

def expand_vars(str)
  return "" if str.nil?

  s = expand_command_substitutions(str.to_s)
  s = s.gsub(/\$\?/) { $last_status.to_s }
  s = s.gsub(/\$(\d+)/) do
    idx = $1.to_i
    ($rsh_positional && $rsh_positional[idx]) || ""
  end
  s.gsub(/\$([a-zA-Z_][a-zA-Z0-9_]*)/) { ENV[$1] || "" }
end

def parse_redirection(cmd)
  stdin_file  = nil
  stdout_file = nil
  stderr_file = nil
  append_out  = false
  append_err  = false

  s = cmd.to_s.dup

  if s =~ /(.*)2>>\s*(\S+)\s*\z/
    s          = $1.strip
    stderr_file= $2.strip
    append_err = true
  elsif s =~ /(.*)2>\s*(\S+)\s*\z/
    s          = $1.strip
    stderr_file= $2.strip
  end

  if s =~ /(.*)>>\s*(\S+)\s*\z/
    s          = $1.strip
    stdout_file= $2.strip
    append_out = true
  elsif s =~ /(.*)>\s*(\S+)\s*\z/
    s          = $1.strip
    stdout_file= $2.strip
  end

  if s =~ /(.*)<\s*(\S+)\s*\z/
    s         = $1.strip
    stdin_file= $2.strip
  end

  [s, stdin_file, stdout_file, append_out, stderr_file, append_err]
end

def with_redirections(stdin_file, stdout_file, append_out, stderr_file, append_err)
  in_dup  = STDIN.dup
  out_dup = STDOUT.dup
  err_dup = STDERR.dup

  if stdin_file
    STDIN.reopen(File.open(stdin_file, 'r')) rescue nil
  end
  if stdout_file
    STDOUT.reopen(File.open(stdout_file, append_out ? 'a' : 'w')) rescue nil
  end
  if stderr_file
    STDERR.reopen(File.open(stderr_file, append_err ? 'a' : 'w')) rescue nil
  end

  yield
ensure
  STDIN.reopen(in_dup)  rescue nil
  STDOUT.reopen(out_dup) rescue nil
  STDERR.reopen(err_dup) rescue nil
  in_dup.close  rescue nil
  out_dup.close rescue nil
  err_dup.close rescue nil
end

def expand_aliases(cmd, seen = [])
  return cmd if cmd.nil? || cmd.strip.empty?
  first_word, rest = cmd.strip.split(' ', 2)
  return cmd if seen.include?(first_word)
  seen << first_word

  if $aliases.key?(first_word)
    replacement = $aliases[first_word]
    expanded    = expand_aliases(replacement, seen)
    rest ? "#{expanded} #{rest}" : expanded
  else
    cmd
  end
end

def current_time
  Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")
end

def detect_distro
  if File.exist?('/etc/os-release')
    line = File.read('/etc/os-release').lines.find { |l|
      l.start_with?('PRETTY_NAME="') || l.start_with?('PRETTY_NAME=')
    }
    return line.split('=').last.strip.delete('"') if line
  end
  "#{RbConfig::CONFIG['host_os']}"
rescue
  "#{RbConfig::CONFIG['host_os']}"
end

def os_type
  host = RbConfig::CONFIG['host_os'].to_s
  case host
  when /linux/i then :linux
  when /darwin/i then :mac
  when /bsd/i then :bsd
  else :other
  end
end

QUOTES = [
  "Listen you flatpaker! - Terry Davis",
  "Btw quotes have made a full rotation, some old ones may not exist (sorry)",
  "Keep calm and ship it.",
  "If it works, don't touch it. (Unless it's legacy, then definitely don't touch it.)",
  "There’s no place like 127.0.0.1.",
  "The computer is never wrong. The user is never right.",
  "Unix is user-friendly. It's just picky about its friends.",
  "A watched process never completes.",
  "Pipes: the original microservices.",
  "If you can read this, your terminal is working. Congrats.",
  "Ctrl+C: the developer's parachute.",
  "Nothing is permanent except the alias you forgot you set.",
  "One does not simply exit vim.",
  "If it compiles, it’s probably fine.",
  "When in doubt, check $PATH.",
  "I/O is lava.",
  "Permissions are a feature, not a bug.",
  "rm -rf is not a personality.",
  "Your shell history knows too much.",
  "If it’s slow, add caching. If it’s still slow, blame DNS.",
  "Kernel panic: the OS's way of saying 'bruh'.",
  "Logs don't lie. They just omit context.",
  "Everything is a file. Including your mistakes.",
  "Segfault: surprise!",
  "If you can't fix it, make it a function.",
  "The quickest optimization is deleting the feature.",
  "Man pages: ancient scrolls of wisdom.",
  "If at first you don’t succeed: read the error message.",
  "The best tool is the one already installed.",
  "A clean build is a suspicious build.",
  "Git is not a backup, but it *tries*.",
  "Sleep: the ultimate debugger.",
  "Bash: because typing 'make it work' was too hard.",
  "In POSIX we trust, in extensions we cope.",
  "How is #{detect_distro}?",
  "If it's on fire: commit, push, walk away.",
]

$current_quote = QUOTES.sample

def dynamic_quote
  return $current_quote unless t(:quote_rainbow)
  chars   = $current_quote.chars
  rainbow = rainbow_codes.cycle
  chars.map { |c| color(c, rainbow.next) }.join
end

def read_cpu_times
  return [] unless File.exist?('/proc/stat')
  cpu_line = File.readlines('/proc/stat').find { |line| line.start_with?('cpu ') }
  return [] unless cpu_line
  cpu_line.split[1..-1].map(&:to_i)
rescue
  []
end

def calculate_cpu_usage(prev, current)
  return 0.0 if prev.empty? || current.empty?
  prev_idle     = prev[3] + (prev[4] || 0)
  idle          = current[3] + (current[4] || 0)
  prev_non_idle = prev[0] + prev[1] + prev[2] + (prev[5] || 0) + (prev[6] || 0) + (prev[7] || 0)
  non_idle      = current[0] + current[1] + current[2] + (current[5] || 0) + (current[6] || 0) + (current[7] || 0)
  prev_total = prev_idle + prev_non_idle
  total      = idle + non_idle
  totald     = total - prev_total
  idled      = idle - prev_idle
  return 0.0 if totald <= 0
  ((totald - idled).to_f / totald) * 100
end

def cpu_cores_and_freq
  return [0, []] unless File.exist?('/proc/cpuinfo')
  cores = 0
  freqs = []
  File.foreach('/proc/cpuinfo') do |line|
    cores += 1 if line =~ /^processor\s*:\s*\d+/
    if line =~ /^cpu MHz\s*:\s*([\d.]+)/
      freqs << $1.to_f
    end
  end
  [cores, freqs.first(cores)]
rescue
  [0, []]
end

def cpu_info
  usage        = 0.0
  cores        = 0
  freq_display = "N/A"

  case os_type
  when :linux
    prev    = read_cpu_times
    sleep 0.05
    current = read_cpu_times
    usage   = calculate_cpu_usage(prev, current).round(1)
    cores, freqs = cpu_cores_and_freq
    freq_display = freqs.empty? ? "N/A" : freqs.map { |f| "#{f.round(0)}MHz" }.join(', ')
  else
    cores = (`sysctl -n hw.ncpu 2>/dev/null`.to_i rescue 0)
    raw_freq_hz = (`sysctl -n hw.cpufrequency 2>/dev/null`.to_i rescue 0)
    freq_display = if raw_freq_hz > 0
      mhz = (raw_freq_hz.to_f / 1_000_000.0).round(0)
      "#{mhz.to_i}MHz"
    else
      "N/A"
    end
    usage = begin
      ps_output = `ps -A -o %cpu 2>/dev/null`
      lines     = ps_output.lines
      values    = lines[1..-1] || []
      sum       = values.map { |l| l.to_f }.inject(0.0, :+)
      cores > 0 ? (sum / cores).round(1) : sum.round(1)
    rescue
      0.0
    end
  end

  "#{ui('CPU',:ui_key)} #{color("#{usage}%", t(:warn))} | " \
  "#{ui('Cores',:ui_key)} #{color(cores.to_s, t(:ok))} | " \
  "#{ui('Freq',:ui_key)} #{color(freq_display, t(:ui_title))}"
end

def ram_info
  case os_type
  when :linux
    if File.exist?('/proc/meminfo')
      meminfo = {}
      File.read('/proc/meminfo').each_line do |line|
        key, val = line.split(':')
        meminfo[key.strip] = val.strip.split.first.to_i * 1024 if key && val
      end
      total = meminfo['MemTotal'] || 0
      free  = (meminfo['MemFree'] || 0) + (meminfo['Buffers'] || 0) + (meminfo['Cached'] || 0)
      used  = total - free
      "#{ui('RAM',:ui_key)} #{color(human_bytes(used), t(:warn))} / #{color(human_bytes(total), t(:ok))}"
    else
      "#{ui('RAM',:ui_key)} Info not available"
    end
  else
    begin
      if os_type == :mac
        total = `sysctl -n hw.memsize 2>/dev/null`.to_i
        return "#{ui('RAM',:ui_key)} Info not available" if total <= 0
        vm = `vm_stat 2>/dev/null`
        page_size = vm[/page size of (\d+) bytes/, 1].to_i
        page_size = 4096 if page_size <= 0
        stats = {}
        vm.each_line do |line|
          if line =~ /^(.+):\s+(\d+)\./
            stats[$1] = $2.to_i
          end
        end
        used_pages = 0
        %w[Pages active Pages wired down Pages occupied by compressor].each do |k|
          used_pages += stats[k].to_i
        end
        used = used_pages * page_size
        "#{ui('RAM',:ui_key)} #{color(human_bytes(used), t(:warn))} / #{color(human_bytes(total), t(:ok))}"
      else
        total = `sysctl -n hw.physmem 2>/dev/null`.to_i
        total = `sysctl -n hw.realmem 2>/dev/null`.to_i if total <= 0
        return "#{ui('RAM',:ui_key)} Info not available" if total <= 0
        "#{ui('RAM',:ui_key)} #{color('Unknown', t(:warn))} / #{color(human_bytes(total), t(:ok))}"
      end
    rescue
      "#{ui('RAM',:ui_key)} Info not available"
    end
  end
end

def storage_info
  begin
    require 'sys/filesystem'
    stat  = Sys::Filesystem.stat(Dir.pwd)
    total = stat.bytes_total
    free  = stat.bytes_available
    used  = total - free
    "#{ui("Disk(#{Dir.pwd})",:ui_key)} #{color(human_bytes(used), t(:warn))} / #{color(human_bytes(total), t(:ok))}"
  rescue LoadError
    "#{color("Install 'sys-filesystem' gem:", t(:err))} #{color('gem install sys-filesystem', t(:warn))}"
  rescue
    "#{ui('Disk',:ui_key)} Info not available"
  end
end

def print_columns_colored(labels)
  return if labels.nil? || labels.empty?
  width           = terminal_width
  visible_lengths = labels.map { |s| strip_ansi(s).length }
  max_len         = visible_lengths.max || 0
  col_width       = [max_len + 2, 4].max
  cols            = [width / col_width, 1].max
  rows            = (labels.length.to_f / cols).ceil

  rows.times do |r|
    line = ""
    cols.times do |c|
      idx = c * rows + r
      break if idx >= labels.length
      label   = labels[idx]
      visible = strip_ansi(label).length
      padding = col_width - visible
      line << label << (" " * padding)
    end
    STDOUT.print("\r")
    STDOUT.print(line.rstrip)
    STDOUT.print("\n")
  end
end

def builtin_ls(path = ".")
  begin
    entries = Dir.children(path).sort
  rescue => e
    puts color("ls: #{e.message}", t(:err))
    return
  end

  labels = entries.map do |name|
    full = File.join(path, name)
    begin
      if File.directory?(full)
        color("#{name}/", t(:ui_hdr))
      elsif File.executable?(full)
        color("#{name}*", t(:ok))
      else
        color(name, t(:ui_val))
      end
    rescue
      name
    end
  end

  print_columns_colored(labels)
end

module Rsh
  Token = Struct.new(:type, :value)

  class Lexer
    def initialize(src)
      @s = src.to_s
      @i = 0
      @n = @s.length
    end

    def next_token
      skip_ws
      return Token.new(:eof, nil) if eof?
      ch = peek

      if ch =~ /[0-9]/
        return read_number
      end

      if ch == '"' || ch == "'"
        return read_string
      end

      if ch == '$'
        advance
        return Token.new(:var, '?') if peek == '?'
        if peek =~ /[0-9]/
          num = read_digits
          return Token.new(:pos, num.to_i)
        end
        ident = read_ident
        return Token.new(:var, ident)
      end

      if ch == '('
        advance
        return Token.new(:lparen, '(')
      end
      if ch == ')'
        advance
        return Token.new(:rparen, ')')
      end
      if ch == ','
        advance
        return Token.new(:comma, ',')
      end

      two = @s[@i, 2]
      three = @s[@i, 3]

      if %w[== != <= >= && || ..].include?(two)
        @i += 2
        return Token.new(:op, two)
      end

      if %w[===].include?(three)
        @i += 3
        return Token.new(:op, three)
      end

      if %w[+ - * / % < > !].include?(ch)
        advance
        return Token.new(:op, ch)
      end

      if ch =~ /[A-Za-z_]/
        ident = read_ident
        type = case ident
               when 'and', 'or', 'not' then :op
               when 'true' then :bool
               when 'false' then :bool
               when 'nil' then :nil
               else :ident
               end
        return Token.new(type, ident)
      end

      advance
      Token.new(:op, ch)
    end

    private

    def eof?
      @i >= @n
    end

    def peek
      @s[@i]
    end

    def advance
      @i += 1
    end

    def skip_ws
      while !eof? && @s[@i] =~ /\s/
        @i += 1
      end
    end

    def read_digits
      start = @i
      while !eof? && @s[@i] =~ /[0-9]/
        @i += 1
      end
      @s[start...@i]
    end

    def read_number
      start = @i
      read_digits
      if !eof? && @s[@i] == '.' && @s[@i+1] =~ /[0-9]/
        @i += 1
        read_digits
      end
      Token.new(:num, @s[start...@i])
    end

    def read_ident
      start = @i
      while !eof? && @s[@i] =~ /[A-Za-z0-9_]/
        @i += 1
      end
      @s[start...@i]
    end

    def read_string
      quote = peek
      advance
      out = +""
      while !eof?
        ch = peek
        advance
        break if ch == quote
        if ch == '\\' && !eof?
          nxt = peek
          advance
          out << case nxt
                 when 'n' then "\n"
                 when 't' then "\t"
                 when 'r' then "\r"
                 when '"' then '"'
                 when "'" then "'"
                 when '\\' then '\\'
                 else nxt
                 end
        else
          out << ch
        end
      end
      Token.new(:str, out)
    end
  end

  class Parser
    def initialize(src)
      @lex = Lexer.new(src)
      @tok = @lex.next_token
    end

    def parse
      expr(0)
    end

    private

    PRECEDENCE = {
      'or' => 1, '||' => 1,
      'and' => 2, '&&' => 2,
      '==' => 3, '!=' => 3, '<' => 3, '<=' => 3, '>' => 3, '>=' => 3,
      '..' => 4,
      '+' => 5, '-' => 5,
      '*' => 6, '/' => 6, '%' => 6,
    }

    def lbp(op)
      PRECEDENCE[op] || 0
    end

    def advance
      @tok = @lex.next_token
    end

    def expect(type)
      t = @tok
      raise "Expected #{type}, got #{t.type}" unless t.type == type
      advance
      t
    end

    def expr(rbp)
      t = @tok
      advance
      left = nud(t)
      while @tok.type == :op && lbp(@tok.value) > rbp
        op = @tok.value
        advance
        left = [:bin, op, left, expr(lbp(op))]
      end
      left
    end

    def nud(t)
      case t.type
      when :num
        if t.value.include?('.')
          [:num, t.value.to_f]
        else
          [:num, t.value.to_i]
        end
      when :str
        [:str, t.value]
      when :bool
        [:bool, t.value == 'true']
      when :nil
        [:nil, nil]
      when :var
        [:var, t.value]
      when :pos
        [:pos, t.value]
      when :ident
        if @tok.type == :lparen
          advance
          args = []
          if @tok.type != :rparen
            loop do
              args << expr(0)
              break if @tok.type == :rparen
              expect(:comma)
            end
          end
          expect(:rparen)
          [:call, t.value, args]
        else
          [:ident, t.value]
        end
      when :op
        if t.value == '-' || t.value == '!' || t.value == 'not'
          [:un, t.value, expr(7)]
        else
          raise "Unexpected operator #{t.value}"
        end
      when :lparen
        e = expr(0)
        expect(:rparen)
        e
      else
        raise "Unexpected token #{t.type}"
      end
    end
  end

  module Eval
    module_function

    def truthy?(v)
      !(v.nil? || v == false)
    end

    def to_num(v)
      return v if v.is_a?(Integer) || v.is_a?(Float)
      s = v.to_s.strip
      return 0 if s.empty?
      return s.to_i if s =~ /\A-?\d+\z/
      return s.to_f if s =~ /\A-?\d+(\.\d+)?\z/
      0
    end

    def to_s(v)
      v.nil? ? "" : v.to_s
    end

    def cmp(a,b)
      if (a.is_a?(Integer) || a.is_a?(Float) || a.to_s =~ /\A-?\d+(\.\d+)?\z/) &&
         (b.is_a?(Integer) || b.is_a?(Float) || b.to_s =~ /\A-?\d+(\.\d+)?\z/)
        to_num(a) <=> to_num(b)
      else
        to_s(a) <=> to_s(b)
      end
    end

    def env_lookup(name, positional, last_status)
      case name
      when '?' then last_status
      else
        ENV[name] || ""
      end
    end

    def eval_ast(ast, positional:, last_status:)
      t = ast[0]
      case t
      when :num then ast[1]
      when :str then ast[1]
      when :bool then ast[1]
      when :nil then nil
      when :var
        env_lookup(ast[1].to_s, positional, last_status)
      when :pos
        (positional[ast[1].to_i] || "")
      when :ident
        ENV[ast[1].to_s] || ""
      when :un
        op, rhs = ast[1], eval_ast(ast[2], positional: positional, last_status: last_status)
        case op
        when '-' then -to_num(rhs)
        when '!', 'not'
          !truthy?(rhs)
        else
          nil
        end
      when :bin
        op = ast[1]
        if op == 'and' || op == '&&'
          l = eval_ast(ast[2], positional: positional, last_status: last_status)
          return false unless truthy?(l)
          r = eval_ast(ast[3], positional: positional, last_status: last_status)
          return truthy?(r)
        elsif op == 'or' || op == '||'
          l = eval_ast(ast[2], positional: positional, last_status: last_status)
          return true if truthy?(l)
          r = eval_ast(ast[3], positional: positional, last_status: last_status)
          return truthy?(r)
        end

        a = eval_ast(ast[2], positional: positional, last_status: last_status)
        b = eval_ast(ast[3], positional: positional, last_status: last_status)

        case op
        when '+'
          if (a.is_a?(Integer) || a.is_a?(Float)) && (b.is_a?(Integer) || b.is_a?(Float))
            a + b
          elsif a.to_s =~ /\A-?\d+(\.\d+)?\z/ && b.to_s =~ /\A-?\d+(\.\d+)?\z/
            to_num(a) + to_num(b)
          else
            to_s(a) + to_s(b)
          end
        when '-'
          to_num(a) - to_num(b)
        when '*'
          to_num(a) * to_num(b)
        when '/'
          den = to_num(b)
          den == 0 ? 0 : (to_num(a).to_f / den.to_f)
        when '%'
          den = to_num(b)
          den == 0 ? 0 : (to_num(a).to_i % den.to_i)
        when '..'
          to_s(a) + to_s(b)
        when '==' then cmp(a,b) == 0
        when '!=' then cmp(a,b) != 0
        when '<'  then cmp(a,b) < 0
        when '<=' then cmp(a,b) <= 0
        when '>'  then cmp(a,b) > 0
        when '>=' then cmp(a,b) >= 0
        else
          nil
        end
      when :call
        name = ast[1].to_s
        args = ast[2].map { |x| eval_ast(x, positional: positional, last_status: last_status) }
        call_fn(name, args, positional: positional, last_status: last_status)
      else
        nil
      end
    end

    def call_fn(name, args, positional:, last_status:)
      case name
      when 'int' then to_num(args[0]).to_i
      when 'float' then to_num(args[0]).to_f
      when 'str' then to_s(args[0])
      when 'len' then to_s(args[0]).length
      when 'empty' then to_s(args[0]).empty?
      when 'contains' then to_s(args[0]).include?(to_s(args[1]))
      when 'starts' then to_s(args[0]).start_with?(to_s(args[1]))
      when 'ends' then to_s(args[0]).end_with?(to_s(args[1]))
      when 'env'
        key = to_s(args[0])
        ENV[key] || ""
      when 'rand'
        n = to_num(args[0]).to_i
        n = 1 if n <= 0
        Kernel.rand(n)
      when 'pick'
        return "" if args.empty?
        args[Kernel.rand(args.length)]
      when 'status'
        last_status
      else
        ""
      end
    rescue
      ""
    end
  end

  NodeCmd   = Struct.new(:line)
  NodeIf    = Struct.new(:cond, :then_nodes, :else_nodes)
  NodeWhile = Struct.new(:cond, :body)
  NodeTimes = Struct.new(:count, :body)
  NodeFn    = Struct.new(:name, :args, :body)

  def self.strip_comment(line)
    in_single = false
    in_double = false
    escaped   = false
    i         = 0
    while i < line.length
      ch = line[i]
      if escaped
        escaped = false
      elsif ch == '\\'
        escaped = true
      elsif ch == "'" && !in_double
        in_single = !in_single
      elsif ch == '"' && !in_single
        in_double = !in_double
      elsif ch == '#' && !in_single && !in_double
        return line[0...i]
      end
      i += 1
    end
    line
  end

  def self.parse_program(lines)
    clean = lines.map { |l| strip_comment(l.to_s).rstrip }
    nodes, _, stop = parse_nodes(clean, 0, [])
    raise "Unexpected #{stop}" if stop
    nodes
  end

  def self.parse_nodes(lines, idx, stop_words)
    nodes = []
    while idx < lines.length
      raw = lines[idx]
      idx += 1
      line = raw.to_s.strip
      next if line.empty?

      if stop_words.include?(line)
        return [nodes, idx - 1, line]
      end

      if line.start_with?("if ")
        cond = line[3..-1].to_s.strip
        then_nodes, idx2, stop = parse_nodes(lines, idx, ['else', 'end'])
        idx = idx2
        else_nodes = []
        if stop == 'else'
          else_nodes, idx3, stop2 = parse_nodes(lines, idx + 1, ['end'])
          idx = idx3
          raise "Unmatched if" unless stop2 == 'end'
          idx += 1
        elsif stop == 'end'
          idx += 1
        else
          raise "Unmatched if"
        end
        nodes << NodeIf.new(cond, then_nodes, else_nodes)
        next
      end

      if line.start_with?("while ")
        cond = line[6..-1].to_s.strip
        body, idx2, stop = parse_nodes(lines, idx, ['end'])
        raise "Unmatched while" unless stop == 'end'
        idx = idx2 + 1
        nodes << NodeWhile.new(cond, body)
        next
      end

      if line.start_with?("times ")
        count = line[6..-1].to_s.strip
        body, idx2, stop = parse_nodes(lines, idx, ['end'])
        raise "Unmatched times" unless stop == 'end'
        idx = idx2 + 1
        nodes << NodeTimes.new(count, body)
        next
      end

      if line.start_with?("fn ")
        parts = line.split(/\s+/)
        name = parts[1]
        args = parts[2..-1] || []
        body, idx2, stop = parse_nodes(lines, idx, ['end'])
        raise "Unmatched fn" unless stop == 'end'
        idx = idx2 + 1
        nodes << NodeFn.new(name, args, body)
        next
      end

      nodes << NodeCmd.new(line)
    end

    [nodes, idx, nil]
  end
end

def eval_rsh_expr(expr)
  return false if expr.nil? || expr.to_s.strip.empty?
  ast = Rsh::Parser.new(expr).parse
  !!Rsh::Eval.eval_ast(ast, positional: $rsh_positional, last_status: $last_status)
rescue
  false
end

def run_rsh_nodes(nodes)
  nodes.each do |node|
    case node
    when Rsh::NodeCmd
      run_input_line(node.line)
    when Rsh::NodeIf
      if eval_rsh_expr(node.cond)
        run_rsh_nodes(node.then_nodes)
      else
        run_rsh_nodes(node.else_nodes)
      end
    when Rsh::NodeWhile
      while eval_rsh_expr(node.cond)
        begin
          run_rsh_nodes(node.body)
        rescue RshBreak
          break
        rescue RshContinue
          next
        end
      end
    when Rsh::NodeTimes
      count_ast = Rsh::Parser.new(node.count).parse
      n = Rsh::Eval.eval_ast(count_ast, positional: $rsh_positional, last_status: $last_status)
      times = n.to_i
      times = 0 if times < 0
      times.times do |i|
        ENV['it'] = i.to_s
        begin
          run_rsh_nodes(node.body)
        rescue RshBreak
          break
        rescue RshContinue
          next
        end
      end
    when Rsh::NodeFn
      $rsh_functions[node.name] = { args: node.args, body: node.body } # keep the body in parsed form
    else
    end
  end
end

def rsh_run_script(script_path, argv)
  $rsh_call_depth += 1
  raise "RSH call depth exceeded" if $rsh_call_depth > 200

  saved_pos = $rsh_positional
  $rsh_positional = {}
  $rsh_positional[0] = File.basename(script_path)
  argv.each_with_index { |val, idx| $rsh_positional[idx + 1] = val.to_s }

  raise "Script too large" if File.exist?(script_path) && File.size(script_path) > 2_000_000

  lines = File.readlines(script_path, chomp: true)
  lines = lines[1..-1] || [] if lines[0] && lines[0].start_with?("#!")
  nodes = Rsh.parse_program(lines)
  run_rsh_nodes(nodes)
ensure
  $rsh_positional = saved_pos
  $rsh_call_depth -= 1
end

def rsh_call_function(name, argv)
  fn = $rsh_functions[name]
  return false unless fn

  $rsh_call_depth += 1
  raise "RSH call depth exceeded" if $rsh_call_depth > 200

  saved_positional = $rsh_positional
  $rsh_positional  = {}
  $rsh_positional[0] = name

  saved_env = {}
  fn[:args].each_with_index do |argname, idx|
    val = (argv[idx] || "").to_s
    saved_env[argname] = ENV.key?(argname) ? ENV[argname] : :__unset__
    ENV[argname] = val
    $rsh_positional[idx + 1] = val
  end

  begin
    run_rsh_nodes(fn[:body])
  rescue RshReturn
  ensure
    saved_env.each do |k, v|
      if v == :__unset__
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
    $rsh_positional = saved_positional
    $rsh_call_depth -= 1
  end
  true
end

def register_builtin(name, &blk)
  $builtins[name.to_s] = blk
end

def register_hook(type, &blk)
  $hooks[type.to_sym] << blk
end

def run_hooks(type, *args)
  $hooks[type.to_sym].each do |blk|
    blk.call(*args)
  rescue
  end
end

class SrshAPI
  def builtin(name, &blk) = register_builtin(name, &blk)
  def hook(type, &blk)    = register_hook(type, &blk)
  def theme(name, hash)   = ($themes[name.to_s] = hash.merge(name: name.to_s))
  def scheme(name)        = set_theme!(name)
  def aliases             = $aliases
end

SRSH = SrshAPI.new

def load_plugins!
  Dir.glob(File.join(SRSH_PLUGINS_DIR, "*.rsh")).sort.each do |path|
    begin
      rsh_run_script(path, [])
    rescue => e
      STDERR.puts(color("plugin(rsh) #{File.basename(path)}: #{e.class}: #{e.message}", t(:err)))
    end
  end

  Dir.glob(File.join(SRSH_PLUGINS_DIR, "*.rb")).sort.each do |path|
    begin
      Kernel.load(path)
    rescue => e
      STDERR.puts(color("plugin(rb) #{File.basename(path)}: #{e.class}: #{e.message}", t(:err)))
    end
  end
rescue
end

def exec_external(args, stdin_file, stdout_file, append_out, stderr_file, append_err)
  command_path = args[0]
  if command_path && (command_path.include?('/') || command_path.start_with?('.'))
    begin
      if File.directory?(command_path)
        puts color("srsh: #{command_path}: is a directory", t(:err))
        $last_status = 126
        return
      end
    rescue
    end
  end

  pid = fork do
    Signal.trap("INT","DEFAULT")
    if stdin_file
      STDIN.reopen(File.open(stdin_file,'r')) rescue nil
    end
    if stdout_file
      STDOUT.reopen(File.open(stdout_file, append_out ? 'a' : 'w')) rescue nil
    end
    if stderr_file
      STDERR.reopen(File.open(stderr_file, append_err ? 'a' : 'w')) rescue nil
    end

    begin
      exec(*args)
    rescue Errno::ENOENT
      STDERR.puts color("Command not found: #{args[0]}", t(:warn))
      exit 127
    rescue Errno::EACCES
      STDERR.puts color("Permission denied: #{args[0]}", t(:err))
      exit 126
    end
  end

  $child_pids << pid
  begin
    Process.wait(pid)
    $last_status = $?.exitstatus || 0
  rescue Interrupt
  ensure
    $child_pids.delete(pid)
  end
end

def builtin_help
  border = ui('=' * 66, :ui_border)
  puts border
  puts ui("srsh #{SRSH_VERSION}", :ui_title) + " " + ui("Builtins", :ui_hdr)
  puts ui("Theme:", :ui_key) + " #{color($theme_name, t(:ui_title))}"
  puts ui("Tip:", :ui_key) + " use #{color('scheme --list', t(:warn))} then #{color('scheme NAME', t(:warn))}"
  puts ui('-' * 66, :ui_border)

  groups = {
    "Core" => {
      "cd [dir]" => "Change directory",
      "pwd" => "Print working directory",
      "ls [dir]" => "List directory (pretty columns)",
      "exit | quit" => "Exit srsh",
      "put TEXT" => "Print text",
    },
    "Config" => {
      "alias [name='cmd']" => "List or set aliases",
      "unalias NAME" => "Remove alias",
      "set [VAR [value...]]" => "List or set variables",
      "unset VAR" => "Unset a variable",
      "read VAR" => "Read a line into a variable",
      "source FILE [args...]" => "Run an RSH script",
      "scheme [--list|NAME]" => "List/set color scheme",
      "plugins" => "List loaded plugin files",
      "reload" => "Reload rc + plugins",
    },
    "Info" => {
      "systemfetch" => "Display system information",
      "jobs" => "Show tracked child jobs",
      "hist" => "Show history",
      "clearhist" => "Clear history (memory + file)",
      "help" => "Show this help",
    },
    "RSH control" => {
      "if EXPR ... [else ...] end" => "Conditional block",
      "while EXPR ... end" => "Loop",
      "times EXPR ... end" => "Loop N times (ENV['it']=index)",
      "fn NAME [args...] ... end" => "Define function",
      "break | continue | return" => "Control flow (scripts)",
      "true | false" => "Always succeed / fail",
      "sleep N" => "Sleep for N seconds",
    }
  }

  col1 = 26
  groups.each do |g, cmds|
    puts ui("\n#{g}:", :ui_hdr)
    cmds.each do |k, v|
      left = k.ljust(col1)
      puts color(left, t(:ui_key)) + color(v, t(:ui_val))
    end
  end

  puts "\n" + border
end

def builtin_systemfetch
  user     = (ENV['USER'] || Etc.getlogin || Etc.getpwuid.name rescue ENV['USER'] || Etc.getlogin)
  host     = Socket.gethostname
  os       = detect_distro
  ruby_ver = RUBY_VERSION

  cpu_percent = begin
    case os_type
    when :linux
      prev = read_cpu_times
      sleep 0.05
      cur  = read_cpu_times
      calculate_cpu_usage(prev, cur).round(1)
    else
      cores = `sysctl -n hw.ncpu 2>/dev/null`.to_i rescue 0
      ps_output = `ps -A -o %cpu 2>/dev/null`
      lines     = ps_output.lines
      values    = lines[1..-1] || []
      sum       = values.map { |l| l.to_f }.inject(0.0, :+)
      cores > 0 ? (sum / cores).round(1) : sum.round(1)
    end
  rescue
    0.0
  end

  mem_percent = begin
    case os_type
    when :linux
      if File.exist?('/proc/meminfo')
        meminfo = {}
        File.read('/proc/meminfo').each_line do |line|
          k, v = line.split(':')
          meminfo[k.strip] = v.strip.split.first.to_i * 1024 if k && v
        end
        total = meminfo['MemTotal'] || 1
        free  = (meminfo['MemAvailable'] || meminfo['MemFree'] || 0)
        used  = total - free
        (used.to_f / total.to_f * 100).round(1)
      else
        0.0
      end
    when :mac
      total = `sysctl -n hw.memsize 2>/dev/null`.to_i
      if total <= 0
        0.0
      else
        vm = `vm_stat 2>/dev/null`
        page_size = vm[/page size of (\d+) bytes/, 1].to_i
        page_size = 4096 if page_size <= 0
        stats = {}
        vm.each_line do |line|
          if line =~ /^(.+):\s+(\d+)\./
            stats[$1] = $2.to_i
          end
        end
        used_pages = 0
        %w[Pages active Pages wired down Pages occupied by compressor].each { |k| used_pages += stats[k].to_i }
        used = used_pages * page_size
        ((used.to_f / total.to_f) * 100).round(1)
      end
    else
      0.0
    end
  rescue
    0.0
  end

  border = ui('=' * 60, :ui_border)
  puts border
  puts ui("srsh System Information", :ui_title)
  puts ui("User:  ", :ui_key) + color("#{user}@#{host}", t(:ui_val))
  puts ui("OS:    ", :ui_key) + color(os, t(:ui_val))
  puts ui("Shell: ", :ui_key) + color("srsh v#{SRSH_VERSION}", t(:ui_val))
  puts ui("Ruby:  ", :ui_key) + color(ruby_ver, t(:ui_val))
  puts ui("CPU:   ", :ui_key) + nice_bar(cpu_percent / 100.0, 30, t(:ok))
  puts ui("RAM:   ", :ui_key) + nice_bar(mem_percent / 100.0, 30, t(:prompt_mark))
  puts border
end

def builtin_jobs
  if $child_pids.empty?
    puts color("No tracked child jobs.", t(:ui_hdr))
    return
  end
  $child_pids.each do |pid|
    status = begin
      Process.kill(0, pid)
      'running'
    rescue Errno::ESRCH
      'done'
    rescue Errno::EPERM
      'running'
    end
    puts "[#{pid}] #{status}"
  end
end

def builtin_hist
  HISTORY.each_with_index { |h, i| printf "%5d  %s\n", i + 1, h }
end

def builtin_clearhist
  HISTORY.clear
  File.delete(HISTORY_FILE) rescue nil
  puts color("History cleared (memory + file).", t(:ok))
end

def builtin_scheme(args)
  a = args[1..-1] || []
  if a.empty?
    puts ui("Theme:", :ui_key) + " #{color($theme_name, t(:ui_title))}"
    return
  end

  if a[0] == "--list" || a[0] == "-l"
    puts ui("Available schemes:", :ui_hdr)
    $themes.keys.sort.each do |k|
      mark = (k == $theme_name) ? color("*", t(:ok)) : " "
      puts " #{mark} #{k}"
    end
    puts ui("User themes dir:", :ui_key) + " #{SRSH_THEMES_DIR}"
    return
  end

  name = a[0].to_s
  if set_theme!(name)
    puts color("scheme: now using '#{name}'", t(:ok))
  else
    puts color("scheme: unknown '#{name}' (try: scheme --list)", t(:err))
    $last_status = 1
  end
end

def builtin_plugins
  rsh = Dir.glob(File.join(SRSH_PLUGINS_DIR, "*.rsh")).sort
  rb  = Dir.glob(File.join(SRSH_PLUGINS_DIR, "*.rb")).sort
  puts ui("Plugins:", :ui_hdr)
  (rsh + rb).each { |p| puts " - #{File.basename(p)}" }
  puts ui("Dir:", :ui_key) + " #{SRSH_PLUGINS_DIR}"
end

def builtin_reload
  begin
    rsh_run_script(RC_FILE, []) if File.exist?(RC_FILE)
    load_plugins!
    puts color("reloaded rc + plugins", t(:ok))
  rescue => e
    puts color("reload: #{e.class}: #{e.message}", t(:err))
    $last_status = 1
  end
end

register_builtin('help') { |args| builtin_help; $last_status = 0 }
register_builtin('systemfetch') { |args| builtin_systemfetch; $last_status = 0 }
register_builtin('jobs') { |args| builtin_jobs; $last_status = 0 }
register_builtin('hist') { |args| builtin_hist; $last_status = 0 }
register_builtin('clearhist') { |args| builtin_clearhist; $last_status = 0 }
register_builtin('scheme') { |args| builtin_scheme(args); $last_status ||= 0 }
register_builtin('plugins') { |args| builtin_plugins; $last_status = 0 }
register_builtin('reload') { |args| builtin_reload; $last_status ||= 0 }

def run_command(cmd, alias_seen = [])
  cmd = cmd.to_s.strip
  return if cmd.empty?

  alias_name = cmd.split(/\s+/, 2).first
  cmd = expand_aliases(cmd, alias_seen.dup)

  if alias_name && split_commands_ops(cmd).length > 1
    run_input_line(cmd, alias_seen: (alias_seen + [alias_name]).uniq)
    return
  end

  cmd = expand_vars(cmd)

  run_hooks(:pre_cmd, cmd)

  if (m = cmd.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/))
    var = m[1]
    val = m[2] || ""
    ENV[var] = val
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  if (m = cmd.match(/\A([A-Za-z_][A-Za-z0-9_]*)\s+=\s+(.+)\z/))
    var = m[1]
    rhs = m[2]
    begin
      ast = Rsh::Parser.new(rhs).parse
      val = Rsh::Eval.eval_ast(ast, positional: $rsh_positional, last_status: $last_status)
      ENV[var] = val.nil? ? "" : val.to_s
      $last_status = 0
    rescue
      ENV[var] = rhs
      $last_status = 0
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  if (m = cmd.match(/\Aemit\s+(.+)\z/))
    expr = m[1]
    begin
      ast = Rsh::Parser.new(expr).parse
      val = Rsh::Eval.eval_ast(ast, positional: $rsh_positional, last_status: $last_status)
      puts(val.nil? ? "" : val.to_s)
      $last_status = 0
    rescue => e
      STDERR.puts color("emit: #{e.class}: #{e.message}", t('error'))
      $last_status = 1
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  cmd2, stdin_file, stdout_file, append_out, stderr_file, append_err = parse_redirection(cmd)
  args = Shellwords.shellsplit(cmd2) rescue []
  return if args.empty?

  if $rsh_functions.key?(args[0])
    ok = rsh_call_function(args[0], args[1..-1] || [])
    $last_status = ok ? 0 : 1
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  if $builtins.key?(args[0])
    with_redirections(stdin_file, stdout_file, append_out, stderr_file, append_err) do
      begin
        $builtins[args[0]].call(args)
      rescue RshBreak
        raise
      rescue RshContinue
        raise
      rescue RshReturn
        raise
      rescue => e
        STDERR.puts color("#{args[0]}: #{e.class}: #{e.message}", t(:err))
        $last_status = 1
      end
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  case args[0]
  when 'ls'
    with_redirections(stdin_file, stdout_file, append_out, stderr_file, append_err) do
      if args.length == 1
        builtin_ls(".")
        $last_status = 0
      elsif args.length == 2 && !args[1].start_with?("-")
        builtin_ls(args[1])
        $last_status = 0
      else
        exec_external(args, stdin_file, stdout_file, append_out, stderr_file, append_err)
      end
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'cd'
    path = args[1] ? File.expand_path(args[1]) : ENV['HOME']
    if !path || !File.exist?(path)
      puts color("cd: no such file or directory: #{args[1]}", t(:err))
      $last_status = 1
    elsif !File.directory?(path)
      puts color("cd: not a directory: #{args[1]}", t(:err))
      $last_status = 1
    else
      Dir.chdir(path)
      $last_status = 0
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'pwd'
    puts color(Dir.pwd, t(:ui_hdr))
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'exit', 'quit'
    $child_pids.each { |pid| Process.kill("TERM", pid) rescue nil }
    exit 0

  when 'alias'
    if args[1].nil?
      $aliases.each { |k,v| puts "#{k}='#{v}'" }
    else
      arg = args[1..].join(' ')
      if arg =~ /^(\w+)=([\"']?)(.+?)\2$/
        $aliases[$1] = $3
      else
        puts color("Invalid alias format", t(:err))
        $last_status = 1
        run_hooks(:post_cmd, cmd, $last_status)
        return
      end
    end
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'unalias'
    if args[1]
      $aliases.delete(args[1])
      $last_status = 0
    else
      puts color("unalias: usage: unalias name", t(:err))
      $last_status = 1
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'put'
    msg = args[1..-1].join(' ')
    puts msg
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'break'
    raise RshBreak
  when 'continue'
    raise RshContinue
  when 'return'
    raise RshReturn

  when 'set'
    if args.length == 1
      ENV.keys.sort.each { |k| puts "#{k}=#{ENV[k]}" }
    else
      var = args[1]
      val = args[2..-1].join(' ')
      ENV[var] = val
    end
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'unset'
    if args[1]
      ENV.delete(args[1])
      $last_status = 0
    else
      puts color("unset: usage: unset VAR", t(:err))
      $last_status = 1
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'read'
    var = args[1]
    unless var
      puts color("read: usage: read VAR", t(:err))
      $last_status = 1
      run_hooks(:post_cmd, cmd, $last_status)
      return
    end
    line = STDIN.gets
    ENV[var] = (line ? line.chomp : "")
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'true'
    $last_status = 0
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'false'
    $last_status = 1
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'sleep'
    secs = (args[1] || "1").to_f
    begin
      Kernel.sleep(secs)
      $last_status = 0
    rescue
      $last_status = 1
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return

  when 'source', '.'
    file = args[1]
    if file.nil?
      puts color("source: usage: source FILE", t(:err))
      $last_status = 1
      run_hooks(:post_cmd, cmd, $last_status)
      return
    end
    begin
      rsh_run_script(file, args[2..-1] || [])
      $last_status = 0
    rescue => e
      STDERR.puts color("source error: #{e.class}: #{e.message}", t(:err))
      $last_status = 1
    end
    run_hooks(:post_cmd, cmd, $last_status)
    return
  end

  exec_external(args, stdin_file, stdout_file, append_out, stderr_file, append_err)
  run_hooks(:post_cmd, cmd, $last_status)
end

def split_commands_ops(input)
  return [] if input.nil?

  tokens    = []
  buf       = +""
  in_single = false
  in_double = false
  escaped   = false
  i         = 0

  push = lambda do |op|
    cmd = buf.strip
    tokens << [op, cmd] unless cmd.empty?
    buf = +""
  end

  current_op = :seq

  while i < input.length
    ch = input[i]

    if escaped
      buf << ch
      escaped = false
    elsif ch == '\\'
      escaped = true
      buf << ch
    elsif ch == "'" && !in_double
      in_single = !in_single
      buf << ch
    elsif ch == '"' && !in_single
      in_double = !in_double
      buf << ch
    elsif !in_single && !in_double
      if ch == ';'
        push.call(current_op)
        current_op = :seq
      elsif ch == '&' && input[i+1] == '&'
        push.call(current_op)
        current_op = :and
        i += 1
      elsif ch == '|' && input[i+1] == '|'
        push.call(current_op)
        current_op = :or
        i += 1
      else
        buf << ch
      end
    else
      buf << ch
    end

    i += 1
  end

  push.call(current_op)
  tokens
end

def run_input_line(input, alias_seen: [])
  split_commands_ops(input).each do |op, cmd|
    case op
    when :seq
      run_command(cmd, alias_seen)
    when :and
      run_command(cmd, alias_seen) if $last_status == 0
    when :or
      run_command(cmd, alias_seen) if $last_status != 0
    end
  end
end

def prompt(hostname)
  "#{color(Dir.pwd, t(:prompt_path))} #{color(hostname, t(:prompt_host))}#{color(' > ', t(:prompt_mark))}"
end

def history_ghost_for(line)
  return nil if line.nil? || line.empty?
  HISTORY.reverse_each do |h|
    next if h.nil? || h.empty?
    next if h.start_with?("[completions:")
    next unless h.start_with?(line)
    next if h == line
    return h
  end
  nil
end

class ExecCache
  def initialize
    @path = nil
    @entries = []
    @built_at = 0.0
  end

  def list
    p = ENV['PATH'].to_s
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @path != p || (now - @built_at) > 2.5
      @path = p
      @built_at = now
      @entries = build_execs(p)
    end
    @entries
  end

  private

  def build_execs(path)
    out = []
    path.split(':').each do |dir|
      next if dir.nil? || dir.empty?
      begin
        Dir.children(dir).each do |entry|
          full = File.join(dir, entry)
          next if File.directory?(full)
          next unless File.executable?(full)
          out << entry
        end
      rescue
      end
    end
    out.uniq
  end
end

$exec_cache = ExecCache.new

def tab_completions_for(prefix, first_word, at_first_word)
  prefix ||= ""

  dir  = "."
  base = prefix

  if prefix.include?('/')
    if prefix.end_with?('/')
      dir  = prefix.chomp('/')
      base = ""
    else
      dir  = File.dirname(prefix)
      base = File.basename(prefix)
    end
    dir = "." if dir.nil? || dir.empty?
  end

  file_completions = []
  if Dir.exist?(dir)
    Dir.children(dir).each do |entry|
      next unless entry.start_with?(base)
      full = File.join(dir, entry)

      rel = if dir == "."
        entry
      else
        File.join(File.dirname(prefix), entry)
      end

      case first_word
      when "cd"
        next unless File.directory?(full)
        rel = rel + "/" unless rel.end_with?("/")
        file_completions << rel
      when "cat"
        next unless File.file?(full)
        file_completions << rel
      else
        rel = rel + "/" if File.directory?(full) && !rel.end_with?("/")
        file_completions << rel
      end
    end
  end

  exec_completions = []
  if first_word != "cat" && first_word != "cd" && at_first_word && !prefix.include?('/')
    exec_completions = $exec_cache.list.grep(/^#{Regexp.escape(prefix)}/)
  end

  (file_completions + exec_completions).uniq
end

def longest_common_prefix(strings)
  return "" if strings.empty?
  shortest = strings.min_by(&:length)
  shortest.length.times do |i|
    c = shortest[i]
    strings.each { |s| return shortest[0...i] if s[i] != c }
  end
  shortest
end

def render_line(prompt_str, buffer, cursor, show_ghost = true)
  buffer = buffer || ""
  cursor = [[cursor, 0].max, buffer.length].min

  ghost_tail = ""
  if show_ghost && cursor == buffer.length
    suggestion = history_ghost_for(buffer)
    ghost_tail = suggestion ? suggestion[buffer.length..-1].to_s : ""
  end

  width = terminal_width
  prompt_vis = strip_ansi(prompt_str).length
  total_vis  = prompt_vis + buffer.length + ghost_tail.length
  rows       = [(total_vis.to_f / width).ceil, 1].max

  if $last_render_rows && $last_render_rows > 0
    STDOUT.print("\r")
    ($last_render_rows - 1).times { STDOUT.print("\e[1A\r") }
    $last_render_rows.times do |i|
      STDOUT.print("\e[0K")
      STDOUT.print("\n") if i < $last_render_rows - 1
    end
    ($last_render_rows - 1).times { STDOUT.print("\e[1A\r") }
  end

  STDOUT.print("\r")
  STDOUT.print(prompt_str)
  STDOUT.print(buffer)

  # Konsole/Breeze likes to ignore "dim"; force an actual gray code instead.
  STDOUT.print(color(ghost_tail, t(:dim))) unless ghost_tail.empty?

  move_left = ghost_tail.length + (buffer.length - cursor)
  STDOUT.print("\e[#{move_left}D") if move_left > 0
  STDOUT.flush

  $last_render_rows = rows
end

def print_tab_list(comps)
  return if comps.empty?

  width     = terminal_width
  max_len   = comps.map(&:length).max || 0
  col_width = [max_len + 2, 4].max
  cols      = [width / col_width, 1].max
  rows      = (comps.length.to_f / cols).ceil

  STDOUT.print("\r\n")
  rows.times do |r|
    line = ""
    cols.times do |c|
      idx = c * rows + r
      break if idx >= comps.length
      item    = comps[idx]
      padding = col_width - item.length
      line   << item << (" " * padding)
    end
    STDOUT.print("\r")
    STDOUT.print(line.rstrip)
    STDOUT.print("\n")
  end
  STDOUT.print("\r\n")
  STDOUT.flush
end

def handle_tab_completion(prompt_str, buffer, cursor, last_tab_prefix)
  buffer = buffer || ""
  cursor = [[cursor, 0].max, buffer.length].min

  wstart = buffer.rindex(/[ \t]/, cursor - 1) || -1
  wstart += 1
  prefix = buffer[wstart...cursor] || ""

  before_word   = buffer[0...wstart]
  at_first_word = before_word.strip.empty?
  first_word    = buffer.strip.split(/\s+/, 2)[0] || ""

  comps = tab_completions_for(prefix, first_word, at_first_word)
  return [buffer, cursor, nil, false] if comps.empty?

  if comps.size == 1
    new_word = comps.first
    buffer   = buffer[0...wstart] + new_word + buffer[cursor..-1].to_s
    cursor   = wstart + new_word.length
    return [buffer, cursor, nil, true]
  end

  if prefix != last_tab_prefix
    lcp = longest_common_prefix(comps)
    if lcp && lcp.length > prefix.length
      buffer = buffer[0...wstart] + lcp + buffer[cursor..-1].to_s
      cursor = wstart + lcp.length
    else
      STDOUT.print("\a")
    end
    return [buffer, cursor, prefix, false]
  end

  render_line(prompt_str, buffer, cursor, false)
  print_tab_list(comps)
  [buffer, cursor, prefix, true]
end

def read_line_with_ghost(prompt_str)
  buffer                 = ""
  cursor                 = 0
  hist_index             = HISTORY.length
  saved_line_for_history = ""
  last_tab_prefix        = nil

  render_line(prompt_str, buffer, cursor)

  status = :ok

  IO.console.raw do |io|
    loop do
      ch = io.getch

      case ch
      when "\r", "\n"
        cursor = buffer.length
        render_line(prompt_str, buffer, cursor, false)
        STDOUT.print("\r\n")
        STDOUT.flush
        break

      when "\u0003"
        STDOUT.print("^C\r\n")
        STDOUT.flush
        status = :interrupt
        buffer = ""
        break

      when "\u0004"
        if buffer.empty?
          status = :eof
          buffer = nil
          STDOUT.print("\r\n")
          STDOUT.flush
          break
        end

      when "\u0001"
        cursor = 0
        last_tab_prefix = nil

      when "\u0005"
        cursor = buffer.length
        last_tab_prefix = nil

      when "\u007F", "\b"
        if cursor > 0
          buffer.slice!(cursor - 1)
          cursor -= 1
        end
        last_tab_prefix = nil

      when "\t"
        buffer, cursor, last_tab_prefix, printed =
          handle_tab_completion(prompt_str, buffer, cursor, last_tab_prefix)
        $last_render_rows = 1 if printed

      when "\e"
        seq1 = io.getch
        seq2 = io.getch
        if seq1 == "[" && seq2
          case seq2
          when "A"
            if hist_index == HISTORY.length
              saved_line_for_history = buffer.dup
            end
            if hist_index > 0
              hist_index -= 1
              buffer      = HISTORY[hist_index] || ""
              cursor      = buffer.length
            end
          when "B"
            if hist_index < HISTORY.length - 1
              hist_index += 1
              buffer      = HISTORY[hist_index] || ""
              cursor      = buffer.length
            elsif hist_index == HISTORY.length - 1
              hist_index = HISTORY.length
              buffer     = saved_line_for_history || ""
              cursor     = buffer.length
            end
          when "C"
            if cursor < buffer.length
              cursor += 1
            else
              suggestion = history_ghost_for(buffer)
              if suggestion
                buffer = suggestion
                cursor = buffer.length
              end
            end
          when "D"
            cursor -= 1 if cursor > 0
          when "H"
            cursor = 0
          when "F"
            cursor = buffer.length
          end
        end
        last_tab_prefix = nil

      else
        if ch.ord >= 32 && ch.ord != 127
          buffer.insert(cursor, ch)
          cursor += 1
          hist_index      = HISTORY.length
          last_tab_prefix = nil
        end
      end

      render_line(prompt_str, buffer, cursor) if status == :ok
    end
  end

  [status, buffer]
end

def print_welcome
  puts color("Welcome to srsh #{SRSH_VERSION}", t(:ui_hdr))
  puts ui("Time:", :ui_key) + " " + color(current_time, t(:ui_val))
  puts cpu_info
  puts ram_info
  puts storage_info
  puts dynamic_quote
  puts
  puts color("Coded by https://github.com/RobertFlexx", t(:dim))
  puts
end

begin
  rsh_run_script(RC_FILE, []) if File.exist?(RC_FILE)
rescue => e
  STDERR.puts color("srshrc: #{e.class}: #{e.message}", t(:err))
end

load_plugins!

if ARGV[0]
  script_path = ARGV.shift
  begin
    rsh_run_script(script_path, ARGV)
  rescue => e
    STDERR.puts color("rsh script error: #{e.class}: #{e.message}", t(:err))
  end
  exit 0
end

print_welcome

hostname = Socket.gethostname

loop do
  print "\033]0;srsh-#{SRSH_VERSION}\007"
  prompt_str = prompt(hostname)

  status, input = read_line_with_ghost(prompt_str)

  break if status == :eof
  next  if status == :interrupt

  next if input.nil?
  input = input.strip
  next if input.empty?

  HISTORY << input
  HISTORY.shift while HISTORY.length > HISTORY_MAX

  run_input_line(input)
end
