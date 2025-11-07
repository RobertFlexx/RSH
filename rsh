#!/usr/bin/env ruby
require 'shellwords'
require 'socket'
require 'time'
require 'etc'
require 'rbconfig'
require 'io/console'

# ---------------- Version ----------------
SRSH_VERSION = "0.7.0"

$0 = "srsh-#{SRSH_VERSION}"
ENV['SHELL'] = "srsh-#{SRSH_VERSION}"
print "\033]0;srsh-#{SRSH_VERSION}\007"

Dir.chdir(ENV['HOME']) if ENV['HOME']

$child_pids       = []
$aliases          = {}
$last_render_rows = 0

$last_status      = 0
$rsh_functions    = {}
$rsh_positional   = {}
$rsh_script_mode  = false

Signal.trap("INT", "IGNORE")

# ---------------- History ----------------
HISTORY_FILE = File.join(Dir.home, ".srsh_history")
HISTORY = if File.exist?(HISTORY_FILE)
File.readlines(HISTORY_FILE, chomp: true)
else
  []
end

at_exit do
  begin
    File.open(HISTORY_FILE, "w") do |f|
      HISTORY.each { |line| f.puts line }
    end
  rescue
  end
end

# ---------------- RC file (create if missing) ----------------
RC_FILE = File.join(Dir.home, ".srshrc")
begin
  unless File.exist?(RC_FILE)
  File.write(RC_FILE, <<~RC)
  # ~/.srshrc — srsh configuration
  # This file was created automatically by srsh v#{SRSH_VERSION}.
  # You can keep personal notes or planned settings here.
  # (Currently not sourced by srsh runtime.)
  RC
  end
rescue
end

# ---------------- Utilities ----------------
def color(text, code)
  "\e[#{code}m#{text}\e[0m"
end

def random_color
  [31, 32, 33, 34, 35, 36, 37].sample
end

def rainbow_codes
  [31, 33, 32, 36, 34, 35, 91, 93, 92, 96, 94, 95]
end

# variable expansion: $VAR and $1, $2, $0 (script/function args)
def expand_vars(str)
  s = str.gsub(/\$([a-zA-Z_][a-zA-Z0-9_]*)/) do
    ENV[$1] || ""
  end
  s.gsub(/\$(\d+)/) do
    idx = $1.to_i
    ($rsh_positional && $rsh_positional[idx]) || ""
  end
end

def parse_redirection(cmd)
  stdin_file  = nil
  stdout_file = nil
  append      = false

  if cmd =~ /(.*)>>\s*(\S+)/
    cmd         = $1.strip
    stdout_file = $2.strip
    append      = true
  elsif cmd =~ /(.*)>\s*(\S+)/
    cmd         = $1.strip
    stdout_file = $2.strip
  end

  if cmd =~ /(.*)<\s*(\S+)/
    cmd        = $1.strip
    stdin_file = $2.strip
  end

  [cmd, stdin_file, stdout_file, append]
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

def nice_bar(p, w = 30, code = 32)
  p = [[p, 0.0].max, 1.0].min
  f = (p * w).round
  b = "█" * f + "░" * (w - f)
  pct = (p * 100).to_i
  "#{color("[#{b}]", code)} #{color(sprintf("%3d%%", pct), 37)}"
end

def terminal_width
  IO.console.winsize[1]
rescue
  80
end

def strip_ansi(str)
  str.to_s.gsub(/\e\[[0-9;]*m/, '')
                     end

                    # ---------------- Aliases ----------------
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

                    # ---------------- System Info ----------------
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
                    end

                    def os_type
                    host = RbConfig::CONFIG['host_os'].to_s
                    case host
                    when /linux/i
                    :linux
                    when /darwin/i
                    :mac
                    when /bsd/i
                    :bsd
                    else
                    :other
                    end
                    end

                    # ---------------- Quotes ----------------
                    QUOTES = [
                              "Keep calm and code on.",
                              "Did you try turning it off and on again?",
                              "There’s no place like 127.0.0.1.",
                              "To iterate is human, to recurse divine.",
                              "sudo rm -rf / – Just kidding, don’t do that!",
                              "The shell is mightier than the sword.",
                              "A journey of a thousand commits begins with a single push.",
                              "In case of fire: git commit, git push, leave building.",
                              "Debugging is like being the detective in a crime movie where you are also the murderer.",
                              "Unix is user-friendly. It's just selective about who its friends are.",
                              "Old sysadmins never die, they just become daemons.",
                              "Listen you flatpaker! – Totally Terry Davis",
                              "How is #{detect_distro}? 🤔",
                              "Life is short, but your command history is eternal.",
                              "If at first you don’t succeed, git commit and push anyway.",
                              "rm -rf: the ultimate trust exercise.",
                              "Coding is like magic, but with more coffee.",
                              "There’s no bug, only undocumented features.",
                              "Keep your friends close and your aliases closer.",
                              "Why wait for the future when you can Ctrl+Z it?",
                              "A watched process never completes.",
                              "When in doubt, make it a function.",
                              "Some call it procrastination, we call it debugging curiosity.",
                              "Life is like a terminal; some commands just don’t execute.",
                              "Good code is like a good joke; it needs no explanation.",
                              "sudo: because sometimes responsibility is overrated.",
                              "Pipes make the world go round.",
                              "In bash we trust, in Ruby we wonder.",
                              "A system without errors is like a day without coffee.",
                              "Keep your loops tight and your sleeps short.",
                              "Stack traces are just life giving you directions.",
                              "Your mom called, she wants her semicolons back."
                             ]

                    $current_quote = QUOTES.sample

                    def dynamic_quote
                    chars   = $current_quote.chars
                    rainbow = rainbow_codes.cycle
                    chars.map { |c| color(c, rainbow.next) }.join
                    end

                    # ---------------- CPU / RAM / Storage ----------------
                    def read_cpu_times
                    return [] unless File.exist?('/proc/stat')
                    cpu_line = File.readlines('/proc/stat').find { |line| line.start_with?('cpu ') }
                    return [] unless cpu_line
                    cpu_line.split[1..-1].map(&:to_i)
                    end

                    def calculate_cpu_usage(prev, current)
                    return 0.0 if prev.empty? || current.empty?
                    prev_idle     = prev[3] + (prev[4] || 0)
                    idle          = current[3] + (current[4] || 0)
                    prev_non_idle = prev[0] + prev[1] + prev[2] +
                    (prev[5] || 0) + (prev[6] || 0) + (prev[7] || 0)
                    non_idle      = current[0] + current[1] + current[2] +
                    (current[5] || 0) + (current[6] || 0) + (current[7] || 0)
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
                    cores = begin
                    `sysctl -n hw.ncpu 2>/dev/null`.to_i
                    rescue
                    0
                    end

                    raw_freq_hz = begin
                    `sysctl -n hw.cpufrequency 2>/dev/null`.to_i
    rescue
      0
    end

    freq_display =
      if raw_freq_hz > 0
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
      if cores > 0
        (sum / cores).round(1)
      else
        sum.round(1)
      end
    rescue
      0.0
    end
  end

  "#{color("CPU Usage:",36)} #{color("#{usage}%",33)} | " \
  "#{color("Cores:",36)} #{color(cores.to_s,32)} | " \
  "#{color("Freqs:",36)} #{color(freq_display,35)}"
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
      "#{color("RAM Usage:",36)} #{color(human_bytes(used),33)} / #{color(human_bytes(total),32)}"
    else
      "#{color("RAM Usage:",36)} Info not available"
    end
  else
    begin
      if os_type == :mac
        total = `sysctl -n hw.memsize 2>/dev/null`.to_i
        return "#{color("RAM Usage:",36)} Info not available" if total <= 0

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

        "#{color("RAM Usage:",36)} #{color(human_bytes(used),33)} / #{color(human_bytes(total),32)}"
      else
        total = `sysctl -n hw.physmem 2>/dev/null`.to_i
        total = `sysctl -n hw.realmem 2>/dev/null`.to_i if total <= 0
        return "#{color("RAM Usage:",36)} Info not available" if total <= 0
        "#{color("RAM Usage:",36)} #{color("Unknown",33)} / #{color(human_bytes(total),32)}"
      end
    rescue
      "#{color("RAM Usage:",36)} Info not available"
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
    "#{color("Storage Usage (#{Dir.pwd}):",36)} #{color(human_bytes(used),33)} / #{color(human_bytes(total),32)}"
  rescue LoadError
    "#{color("Install 'sys-filesystem' gem for storage info:",31)} #{color('gem install sys-filesystem',33)}"
  rescue
    "#{color("Storage Usage:",36)} Info not available"
  end
end

# ---------------- Builtin helpers ----------------
def builtin_help
  puts color('=' * 60, "1;35")
  puts color("srsh #{SRSH_VERSION} - Builtin Commands", "1;33")
  puts color(sprintf("%-15s%-45s", "Command", "Description"), "1;36")
  puts color('-' * 60, "1;34")
  puts color(sprintf("%-15s", "cd"), "1;36")          + "Change directory"
  puts color(sprintf("%-15s", "pwd"), "1;36")         + "Print working directory"
  puts color(sprintf("%-15s", "exit / quit"), "1;36") + "Exit the shell"
  puts color(sprintf("%-15s", "alias"), "1;36")       + "Create or list aliases"
  puts color(sprintf("%-15s", "unalias"), "1;36")     + "Remove alias"
  puts color(sprintf("%-15s", "jobs"), "1;36")        + "Show background jobs (tracked pids)"
  puts color(sprintf("%-15s", "systemfetch"), "1;36") + "Display system information"
  puts color(sprintf("%-15s", "hist"), "1;36")        + "Show shell history"
  puts color(sprintf("%-15s", "clearhist"), "1;36")   + "Clear saved history (memory + file)"
  puts color(sprintf("%-15s", "put"), "1;36")         + "Print text (like echo)"
  puts color(sprintf("%-15s", "help"), "1;36")        + "Show this help message"
  puts color('=' * 60, "1;35")
end

def builtin_systemfetch
  user     = ENV['USER'] || Etc.getlogin || Etc.getpwuid.name rescue ENV['USER'] || Etc.getlogin
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
      if cores > 0
        (sum / cores).round(1)
      else
        sum.round(1)
      end
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
        %w[Pages active Pages wired down Pages occupied by compressor].each do |k|
          used_pages += stats[k].to_i
        end
        used = used_pages * page_size
        ((used.to_f / total.to_f) * 100).round(1)
      end
    else
      0.0
    end
  rescue
    0.0
  end

  puts color('=' * 60, "1;35")
  puts color("srsh System Information", "1;33")
  puts color("User:        ", "1;36") + color("#{user}@#{host}", "0;37")
  puts color("OS:          ", "1;36") + color(os, "0;37")
  puts color("Shell:       ", "1;36") + color("srsh v#{SRSH_VERSION}", "0;37")
  puts color("Ruby:        ", "1;36") + color(ruby_ver, "0;37")
  puts color("CPU Usage:   ", "1;36") + nice_bar(cpu_percent / 100.0, 30, 32)
  puts color("RAM Usage:   ", "1;36") + nice_bar(mem_percent / 100.0, 30, 35)
  puts color('=' * 60, "1;35")
end

def builtin_jobs
  if $child_pids.empty?
    puts color("No tracked child jobs.", 36)
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
  HISTORY.each_with_index do |h, i|
    printf "%5d  %s\n", i + 1, h
  end
end

def builtin_clearhist
  HISTORY.clear
  if File.exist?(HISTORY_FILE)
    begin
      File.delete(HISTORY_FILE)
    rescue
    end
  end
  puts color("History cleared (memory + file).", 32)
end

# -------- Pretty column printer for colored text (used by ls) --------
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
    puts color("ls: #{e.message}", 31)
    return
  end

  labels = entries.map do |name|
    full = File.join(path, name)
    begin
      if File.directory?(full)
        color("#{name}/", 36)
      elsif File.executable?(full)
        color("#{name}*", 32)
      else
        color(name, 37)
      end
    rescue
      name
    end
  end

  print_columns_colored(labels)
end

# ---------------- rsh scripting helpers ----------------

# Evaluate rsh condition expressions, Ruby-style with $VARS
def eval_rsh_expr(expr)
  return false if expr.nil? || expr.strip.empty?
  s = expr.to_s

  s = s.gsub(/\$([A-Za-z_][A-Za-z0-9_]*)/) do
    (ENV[$1] || "").inspect
  end

  s = s.gsub(/\$(\d+)/) do
    idx = $1.to_i
    val = ($rsh_positional && $rsh_positional[idx]) || ""
    val.inspect
  end

  begin
    !!eval(s)
  rescue
    false
  end
end

def rsh_find_if_bounds(lines, start_idx)
  depth    = 1
  else_idx = nil
  i        = start_idx + 1
  while i < lines.length
    line = lines[i].to_s.strip
    if line.start_with?("if ")
      depth += 1
    elsif line.start_with?("while ")
      depth += 1
    elsif line.start_with?("fn ")
      depth += 1
    elsif line == "end"
      depth -= 1
      return [else_idx, i] if depth == 0
    elsif line == "else" && depth == 1
      else_idx = i
    end
    i += 1
  end
  raise "Unmatched 'if' in rsh script"
end

def rsh_find_block_end(lines, start_idx)
  depth = 1
  i     = start_idx + 1
  while i < lines.length
    line = lines[i].to_s.strip
    if line.start_with?("if ") || line.start_with?("while ") || line.start_with?("fn ")
      depth += 1
    elsif line == "end"
      depth -= 1
      return i if depth == 0
    end
    i += 1
  end
  raise "Unmatched block in rsh script"
end

def run_rsh_block(lines, start_idx, end_idx)
  i = start_idx
  while i < end_idx
    raw  = lines[i]
    i   += 1
    next if raw.nil?
    line = raw.strip
    next if line.empty? || line.start_with?("#")

    if line.start_with?("if ")
      cond_expr           = line[3..-1].strip
      else_idx, end_idx_2 = rsh_find_if_bounds(lines, i - 1)
      if eval_rsh_expr(cond_expr)
        body_end = else_idx || end_idx_2
        run_rsh_block(lines, i, body_end)
      elsif else_idx
        run_rsh_block(lines, else_idx + 1, end_idx_2)
      end
      i = end_idx_2 + 1
      next
    elsif line.start_with?("while ")
      cond_expr = line[6..-1].strip
      block_end = rsh_find_block_end(lines, i - 1)
      while eval_rsh_expr(cond_expr)
        run_rsh_block(lines, i, block_end)
      end
      i = block_end + 1
      next
    elsif line.start_with?("fn ")
      parts     = line.split
      name      = parts[1]
      argnames  = parts[2..-1] || []
      block_end = rsh_find_block_end(lines, i - 1)
      $rsh_functions[name] = {
        args: argnames,
        body: lines[i...block_end]
      }
      i = block_end + 1
      next
    else
      run_input_line(line)
    end
  end
end

def rsh_run_script(script_path, argv)
  $rsh_script_mode = true
  $rsh_positional  = {}
  $rsh_positional[0] = File.basename(script_path)
  argv.each_with_index do |val, idx|
    $rsh_positional[idx + 1] = val
  end

  lines = File.readlines(script_path, chomp: true)
  if lines[0] && lines[0].start_with?("#!")
    lines = lines[1..-1] || []
  end
  run_rsh_block(lines, 0, lines.length)
end

def rsh_call_function(name, argv)
  fn = $rsh_functions[name]
  return unless fn

  saved_positional = $rsh_positional
  $rsh_positional  = {}
  $rsh_positional[0] = name
  fn[:args].each_with_index do |argname, idx|
    val = argv[idx] || ""
    ENV[argname] = val
    $rsh_positional[idx + 1] = val
  end

  run_rsh_block(fn[:body], 0, fn[:body].length)
ensure
  $rsh_positional = saved_positional
end

# ---------------- External Execution Helper ----------------
def exec_external(args, stdin_file, stdout_file, append)
  command_path = args[0]
  if command_path && (command_path.include?('/') || command_path.start_with?('.'))
    begin
      if File.directory?(command_path)
        puts color("srsh: #{command_path}: is a directory", 31)
        return
      end
    rescue
    end
  end

  pid = fork do
    Signal.trap("INT","DEFAULT")
    if stdin_file
      begin
        STDIN.reopen(File.open(stdin_file,'r'))
      rescue
      end
    end
    if stdout_file
      begin
        STDOUT.reopen(File.open(stdout_file, append ? 'a' : 'w'))
      rescue
      end
    end
    begin
      exec(*args)
    rescue Errno::ENOENT
      puts color("Command not found: #{args[0]}", rainbow_codes.sample)
      exit 127
    rescue Errno::EACCES
      puts color("Permission denied: #{args[0]}", 31)
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

# ---------------- Command Execution ----------------
def run_command(cmd)
  cmd = cmd.to_s
  cmd = expand_aliases(cmd.strip)
  cmd = expand_vars(cmd.strip)
  cmd, stdin_file, stdout_file, append = parse_redirection(cmd)
  args = Shellwords.shellsplit(cmd) rescue []
  return if args.empty?

  # rsh functions
  if $rsh_functions.key?(args[0])
    rsh_call_function(args[0], args[1..-1] || [])
    return
  end

  case args[0]
  when 'ls'
    if args.length == 1
      builtin_ls(".")
      return
    elsif args.length == 2 && !args[1].start_with?("-")
      builtin_ls(args[1])
      return
    end
    exec_external(args, stdin_file, stdout_file, append)
    return
  when 'cd'
    path = args[1] ? File.expand_path(args[1]) : ENV['HOME']
    if !File.exist?(path)
      puts color("cd: no such file or directory: #{args[1]}", 31)
    elsif !File.directory?(path)
      puts color("cd: not a directory: #{args[1]}", 31)
    else
      Dir.chdir(path)
    end
    return
  when 'exit','quit'
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
        puts color("Invalid alias format", 31)
      end
    end
    return
  when 'unalias'
    if args[1]
      $aliases.delete(args[1])
    else
      puts color("unalias: usage: unalias name", 31)
    end
    return
  when 'help'
    builtin_help
    return
  when 'systemfetch'
    builtin_systemfetch
    return
  when 'jobs'
    builtin_jobs
    return
  when 'pwd'
    puts color(Dir.pwd, 36)
    return
  when 'hist'
    builtin_hist
    return
  when 'clearhist'
    builtin_clearhist
    return
  when 'put'
    msg = args[1..-1].join(' ')
    puts msg
    return
  end

  exec_external(args, stdin_file, stdout_file, append)
end

# ---------------- Chained Commands ----------------
def run_input_line(input)
  commands = input.split(/&&|;/).map(&:strip)
  commands.each do |cmd|
    next if cmd.empty?
    run_command(cmd)
  end
end

# ---------------- Prompt ----------------
hostname     = Socket.gethostname
prompt_color = random_color

def prompt(hostname, prompt_color)
  "#{color(Dir.pwd,33)} #{color(hostname,36)}#{color(' > ', prompt_color)}"
end

# ---------------- Ghost + Completion Helpers ----------------
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

      rel =
        if dir == "."
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
    path_entries = (ENV['PATH'] || "").split(':')
    execs = path_entries.flat_map do |p|
      Dir.glob("#{p}/*").map { |f|
        File.basename(f) if File.executable?(f) && !File.directory?(f)
      }.compact rescue []
    end
    exec_completions = execs.grep(/^#{Regexp.escape(prefix)}/)
  end

  (file_completions + exec_completions).uniq
end

def longest_common_prefix(strings)
  return "" if strings.empty?
  shortest = strings.min_by(&:length)
  shortest.length.times do |i|
    c = shortest[i]
    strings.each do |s|
      return shortest[0...i] if s[i] != c
    end
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

  # Clear previous render block (only what we drew last time)
  if $last_render_rows && $last_render_rows > 0
    STDOUT.print("\r")
    ($last_render_rows - 1).times do
      STDOUT.print("\e[1A\r") # move up a line, to column 0
    end
    $last_render_rows.times do |i|
      STDOUT.print("\e[0K")   # clear this line
      STDOUT.print("\n") if i < $last_render_rows - 1
    end
    ($last_render_rows - 1).times do
      STDOUT.print("\e[1A\r") # move back up to first line of block
    end
  end

  STDOUT.print("\r")
  STDOUT.print(prompt_str)
  STDOUT.print(buffer)
  STDOUT.print(color(ghost_tail, "2")) unless ghost_tail.empty?

  move_left = ghost_tail.length + (buffer.length - cursor)
  STDOUT.print("\e[#{move_left}D") if move_left > 0
  STDOUT.flush

  $last_render_rows = rows
end

# --------- NEAT MULTI-COLUMN TAB LIST (bash-style) ----------
def print_tab_list(comps)
  return if comps.empty?

  width     = terminal_width
  max_len   = comps.map { |s| s.length }.max || 0
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

def handle_tab_completion(prompt_str, buffer, cursor, last_tab_prefix, tab_cycle)
  buffer = buffer || ""
  cursor = [[cursor, 0].max, buffer.length].min

  wstart = buffer.rindex(/[ \t]/, cursor - 1) || -1
  wstart += 1
  prefix = buffer[wstart...cursor] || ""

  before_word   = buffer[0...wstart]
  at_first_word = before_word.strip.empty?
  first_word    = buffer.strip.split(/\s+/, 2)[0] || ""

  comps = tab_completions_for(prefix, first_word, at_first_word)
  return [buffer, cursor, nil, 0, false] if comps.empty?

  if comps.size == 1
    new_word = comps.first
    buffer   = buffer[0...wstart] + new_word + buffer[cursor..-1].to_s
    cursor   = wstart + new_word.length
    return [buffer, cursor, nil, 0, true]
  end

  if prefix != last_tab_prefix
    lcp = longest_common_prefix(comps)
    if lcp && lcp.length > prefix.length
      buffer = buffer[0...wstart] + lcp + buffer[cursor..-1].to_s
      cursor = wstart + lcp.length
    else
      STDOUT.print("\a")
    end
    last_tab_prefix = prefix
    tab_cycle       = 1
    return [buffer, cursor, last_tab_prefix, tab_cycle, false]
  else
    # Second tab on same prefix: show list
    render_line(prompt_str, buffer, cursor, false)
    print_tab_list(comps)
    last_tab_prefix = prefix
    tab_cycle      += 1
    return [buffer, cursor, last_tab_prefix, tab_cycle, true]
  end
end

def read_line_with_ghost(prompt_str)
  buffer                 = ""
  cursor                 = 0
  hist_index             = HISTORY.length
  saved_line_for_history = ""
  last_tab_prefix        = nil
  tab_cycle              = 0

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
      when "\u0003" # Ctrl-C
        STDOUT.print("^C\r\n")
        STDOUT.flush
        status = :interrupt
        buffer = ""
        break
      when "\u0004" # Ctrl-D
        if buffer.empty?
          status = :eof
          buffer = nil
          STDOUT.print("\r\n")
          STDOUT.flush
          break
        else
          # ignore when line not empty
        end
      when "\u0001" # Ctrl-A - move to beginning of line
        cursor = 0
        last_tab_prefix = nil
        tab_cycle       = 0
      when "\u007F", "\b" # Backspace
        if cursor > 0
          buffer.slice!(cursor - 1)
          cursor -= 1
        end
        last_tab_prefix = nil
        tab_cycle       = 0
      when "\t" # Tab completion
        buffer, cursor, last_tab_prefix, tab_cycle, printed =
          handle_tab_completion(prompt_str, buffer, cursor, last_tab_prefix, tab_cycle)
        # After showing completion list, reset render rows so the next prompt
        # redraw only clears the current input line, not the completion block.
        $last_render_rows = 1 if printed
      when "\e" # Escape sequences (arrows, home/end)
        seq1 = io.getch
        seq2 = io.getch
        if seq1 == "[" && seq2
          case seq2
          when "A" # Up
            if hist_index == HISTORY.length
              saved_line_for_history = buffer.dup
            end
            if hist_index > 0
              hist_index -= 1
              buffer      = HISTORY[hist_index] || ""
              cursor      = buffer.length
            end
          when "B" # Down
            if hist_index < HISTORY.length - 1
              hist_index += 1
              buffer      = HISTORY[hist_index] || ""
              cursor      = buffer.length
            elsif hist_index == HISTORY.length - 1
              hist_index = HISTORY.length
              buffer     = saved_line_for_history || ""
              cursor     = buffer.length
            end
          when "C" # Right
            if cursor < buffer.length
              cursor += 1
            else
              suggestion = history_ghost_for(buffer)
              if suggestion
                buffer = suggestion
                cursor = buffer.length
              end
            end
          when "D" # Left
            cursor -= 1 if cursor > 0
          when "H" # Home
            cursor = 0
          when "F" # End
            cursor = buffer.length
          end
        end
        last_tab_prefix = nil
        tab_cycle       = 0
      else
        if ch.ord >= 32 && ch.ord != 127
          buffer.insert(cursor, ch)
          cursor += 1
          hist_index      = HISTORY.length
          last_tab_prefix = nil
          tab_cycle       = 0
        end
      end

      render_line(prompt_str, buffer, cursor) if status == :ok
    end
  end

  [status, buffer]
end

# ---------------- Welcome ----------------
def print_welcome
  puts color("Welcome to srsh #{SRSH_VERSION} - your simple Ruby shell!",36)
  puts color("Current Time:",36) + " " + color(current_time,34)
  puts cpu_info
  puts ram_info
  puts storage_info
  puts dynamic_quote
  puts
  puts color("Coded with love by https://github.com/RobertFlexx",90)
  puts
end

# ---------------- Script vs interactive entry ----------------
if ARGV[0]
  script_path = ARGV.shift
  begin
    rsh_run_script(script_path, ARGV)
  rescue => e
    STDERR.puts "rsh script error: #{e.class}: #{e.message}"
  end
  exit 0
end

print_welcome

# ---------------- Main Loop ----------------
loop do
  print "\033]0;srsh-#{SRSH_VERSION}\007"
  prompt_str = prompt(hostname, prompt_color)

  status, input = read_line_with_ghost(prompt_str)

  break if status == :eof
  next  if status == :interrupt

  next if input.nil?
  input = input.strip
  next if input.empty?

  HISTORY << input

  run_input_line(input)
end
