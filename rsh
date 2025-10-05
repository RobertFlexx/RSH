#!/usr/bin/env ruby
require 'readline'
require 'shellwords'
require 'socket'
require 'time'

# ---------------- Version ----------------
SRSH_VERSION = "0.2.1"

$0 = "srsh-#{SRSH_VERSION}"
ENV['SHELL'] = "srsh-#{SRSH_VERSION}"
print "\033]0;srsh-#{SRSH_VERSION}\007"

Dir.chdir(ENV['HOME'])

$child_pids = []
$aliases = {}

# ---------------- Utilities ----------------
def color(text, code)
    "\e[#{code}m#{text}\e[0m"
end

def random_color
    [31,32,33,34,35,36,37].sample
end

def random_rainbow_color
    [31,33,32,36,34,35,91,93,92,96,94,95].sample
end

def expand_vars(str)
    str.gsub(/\$([a-zA-Z_][a-zA-Z0-9_]*)/) { ENV[$1] || "" }
end

def parse_redirection(cmd)
    stdin_file = nil
    stdout_file = nil
    append = false

    if cmd =~ /(.*)>>(\s*\S+)/
        cmd = $1.strip
        stdout_file = $2.strip
        append = true
    elsif cmd =~ /(.*)>(\s*\S+)/
        cmd = $1.strip
        stdout_file = $2.strip
    end

    if cmd =~ /(.*)<(\s*\S+)/
        cmd = $1.strip
        stdin_file = $2.strip
    end

    [cmd, stdin_file, stdout_file, append]
end

def human_bytes(bytes)
    units = ['B','KB','MB','GB','TB']
    size = bytes.to_f
    unit = units.shift
    while size > 1024 && !units.empty?
        size /= 1024
        unit = units.shift
    end
    "#{format('%.2f', size)} #{unit}"
end

# ---------------- Aliases ----------------
def expand_aliases(cmd, seen = [])
    return cmd if cmd.strip.empty?
    first_word, rest = cmd.strip.split(' ', 2)
    return cmd if seen.include?(first_word)
    seen << first_word

    if $aliases.key?(first_word)
        replacement = $aliases[first_word]
        expanded = expand_aliases(replacement, seen)
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
        line = File.read('/etc/os-release').lines.find { |l| l.start_with?("PRETTY_NAME=") }
        return line.split('=').last.strip.delete('"') if line
    end
    "Linux"
end

def random_quote
    distro = detect_distro
    quotes = [
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
        "How is #{distro}? 🤔"
    ]
    color(quotes.sample, 35)
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
    prev_idle = prev[3] + (prev[4]||0)
    idle = current[3] + (current[4]||0)
    prev_non_idle = prev[0]+prev[1]+prev[2]+(prev[5]||0)+(prev[6]||0)+(prev[7]||0)
    non_idle = current[0]+current[1]+current[2]+(current[5]||0)+(current[6]||0)+(current[7]||0)
    prev_total = prev_idle + prev_non_idle
    total = idle + non_idle
    totald = total - prev_total
    idled = idle - prev_idle
    return 0.0 if totald <= 0
    ((totald - idled).to_f / totald) * 100
end

def cpu_cores_and_freq
    return [0,[]] unless File.exist?('/proc/cpuinfo')
    cores = 0
    freqs = []
    File.foreach('/proc/cpuinfo') do |line|
        cores += 1 if line =~ /^processor\s*:\s*\d+/
                freqs << $1.to_f if line =~ /^cpu MHz\s*:\s*([\d.]+)/
                end
        [cores, freqs.first(cores)]
    end

    def cpu_info
        prev = read_cpu_times
        sleep(0.05)
        current = read_cpu_times
        usage = calculate_cpu_usage(prev, current).round(1)
        cores, freqs = cpu_cores_and_freq
        freq_display = freqs.empty? ? "N/A" : freqs.map { |f| "#{f.round(0)}MHz"}.join(', ')
        color("CPU Usage:",36)+" #{color("#{usage}%",33)} | "+color("Cores:",36)+" #{color(cores.to_s,32)} | "+color("Freqs:",36)+" #{color(freq_display,35)}"
    end

    def ram_info
        if File.exist?('/proc/meminfo')
            meminfo = {}
            File.read('/proc/meminfo').each_line do |line|
                key,val = line.split(':')
                meminfo[key.strip] = val.strip.split.first.to_i * 1024
            end
            total = meminfo['MemTotal'] || 0
            free = (meminfo['MemFree']||0) + (meminfo['Buffers']||0) + (meminfo['Cached']||0)
            used = total - free
            color("RAM Usage:",36)+" #{color(human_bytes(used),33)} / #{color(human_bytes(total),32)}"
        else
            color("RAM Usage:",36)+" Info not available"
        end
    end

    def storage_info
        begin
            require 'sys/filesystem'
            stat = Sys::Filesystem.stat(Dir.pwd)
            total = stat.bytes_total
            free = stat.bytes_available
            used = total - free
            color("Storage Usage (#{Dir.pwd}):",36)+" #{color(human_bytes(used),33)} / #{color(human_bytes(total),32)}"
        rescue LoadError
            color("Install 'sys-filesystem' gem for storage info:",31)+" #{color('gem install sys-filesystem',33)}"
        rescue
            color("Storage Usage:",36)+" Info not available"
        end
    end

    # ---------------- Command Execution ----------------
    def run_command(cmd)
        cmd = expand_aliases(cmd.strip)
        cmd = expand_vars(cmd.strip)
        cmd, stdin_file, stdout_file, append = parse_redirection(cmd)
        args = Shellwords.shellsplit(cmd)
        return if args.empty?

        case args[0]
        when 'cd'
            path = args[1] ? File.expand_path(args[1]) : ENV['HOME']
            if !File.exist?(path)
                puts color("cd: no such file or directory: #{args[1]}",31)
            elsif !File.directory?(path)
                puts color("cd: not a directory: #{args[1]}",31)
            else
                Dir.chdir(path)
            end
            return
        when 'exit','quit'
            puts color("Bye!",36)
            $child_pids.each { |pid| Process.kill("TERM", pid) rescue nil }
            exit 0
        when 'alias'
            if args[1].nil?
                $aliases.each { |k,v| puts "#{k}='#{v}'" }
            else
                arg = args[1..].join(' ')
                if arg =~ /^(\w+)=(["']?)(.+?)\2$/
                        $aliases[$1] = $3
                else
                    puts color("Invalid alias format",31)
                end
            end
            return
        when 'unalias'
            if args[1]
                $aliases.delete(args[1])
            else
                puts color("unalias: usage: unalias name",31)
            end
            return
        end

        pid = fork do
            Signal.trap("INT","DEFAULT")
            STDIN.reopen(File.open(stdin_file,'r')) if stdin_file rescue nil
            STDOUT.reopen(File.open(stdout_file, append ? 'a' : 'w')) if stdout_file rescue nil
            begin
                exec(*args)
            rescue Errno::ENOENT
                puts color("Command not found: #{args[0]}", random_rainbow_color)
                exit 127
            end
        end

        $child_pids << pid
        begin
            Process.wait(pid)
        rescue Interrupt
            $child_pids.each { |c| Process.kill("INT", c) rescue nil }
        ensure
            $child_pids.delete(pid)
        end
    end

    # ---------------- Prompt ----------------
    hostname = Socket.gethostname
    prompt_color = random_color
    def prompt(hostname, prompt_color)
        "#{color(Dir.pwd,33)} #{color(hostname,36)}#{color(' > ', prompt_color)}"
    end

    # ---------------- Completion ----------------
    Readline.completion_append_character = ' '
    Readline.completion_proc = proc do |s|
        files = Dir.glob("#{s}*").map { |f| File.directory?(f) ? "#{f}/" : f }
        @executables ||= ENV['PATH'].split(':').flat_map { |p| Dir.glob("#{p}/*").map { |f| File.basename(f) if File.executable?(f) }.compact }
        (files + @executables.grep(/^#{Regexp.escape(s)}/)).uniq
    rescue
        []
    end

    # ---------------- Ctrl+C Handling ----------------
    Signal.trap("INT") do
        if $child_pids.any?
            $child_pids.each { |pid| Process.kill("INT", pid) rescue nil }
        else
            print "\n^C\n"
            Readline::HISTORY.push('') if Readline::HISTORY.empty? || Readline::HISTORY[-1] != ''
            print prompt(Socket.gethostname, random_color)
        end
    end

    # ---------------- Welcome ----------------
    def print_welcome
        puts color("Welcome to srsh #{SRSH_VERSION} - your simple Ruby shell!",36)
        puts color("Current Time:",36)+" #{color(current_time,34)}"
        puts cpu_info
        puts ram_info
        puts storage_info
        puts random_quote
        puts
        puts color("Coded with love by https://github.com/RobertFlexx",90)
        puts
    end
    print_welcome

    # ---------------- Main Loop ----------------
    loop do
        print "\033]0;srsh-#{SRSH_VERSION}\007"
        begin
            input = Readline.readline(prompt(hostname,prompt_color), true)
            break if input.nil?
            input.strip!
            next if input.empty?
        rescue Interrupt
            next
        end

        Readline::HISTORY.pop if input.empty?

        if ['exit','quit'].include?(input)
            print color("Do you really wanna leave me? (y/n) ",35)
            answer = $stdin.gets.chomp.downcase
            if ['y','yes'].include?(answer)
                puts color("Bye! Take care!",36)
                $child_pids.each { |pid| Process.kill("TERM", pid) rescue nil }
                break
            else
                next
            end
        end

        background = input.end_with?('&')
        input.chomp!('&') if background
        pipeline = input.split('|').map(&:strip)

        if pipeline.size == 1
            run_command(pipeline.first)
            next
        end

        # ---------------- Pipeline ----------------
        procs = []
        prev_read = nil
        pipeline.each_with_index do |cmd,i|
            read_pipe, write_pipe = IO.pipe unless i == pipeline.size - 1
            pid = fork do
                Signal.trap("INT","DEFAULT")
                STDIN.reopen(prev_read) if prev_read rescue nil
                STDOUT.reopen(write_pipe) if i < pipeline.size - 1 rescue nil
                exec(*Shellwords.shellsplit(expand_vars(cmd))) rescue puts color("Command not found: #{cmd}", random_rainbow_color)
            end
            $child_pids << pid

            prev_read.close if prev_read rescue nil
            write_pipe.close if write_pipe rescue nil
            prev_read = read_pipe
            procs << pid
        end

        procs.each do |pid|
            begin
                Process.wait(pid) unless background
            rescue Interrupt
                $child_pids.each { |c| Process.kill("INT", c) rescue nil }
            ensure
                $child_pids.delete(pid)
            end
        end
    end

