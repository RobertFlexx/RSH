#!/usr/bin/env ruby
require 'readline'
require 'shellwords'
require 'socket'
require 'time'


$0 = "srsh"
ENV['SHELL'] = 'srsh'

print "\033]0;srsh\007"
Dir.chdir(ENV['HOME'])

def color(text, code)
    "\e[#{code}m#{text}\e[0m"
end

def random_color_code
    [31, 32, 33, 34, 35, 36, 37].sample
end

def random_rainbow_color
    [31, 33, 32, 36, 34, 35, 91, 93, 92, 96, 94, 95].sample
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
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    size = bytes.to_f
    unit = units.shift
    while size > 1024 && !units.empty?
        size /= 1024
        unit = units.shift
    end
    "#{format('%.2f', size)} #{unit}"
end

def ram_info
    if File.exist?('/proc/meminfo')
        meminfo = {}
        File.read('/proc/meminfo').each_line do |line|
            key, val = line.split(':')
            meminfo[key.strip] = val.strip.split.first.to_i * 1024
        end
        total = meminfo['MemTotal'] || 0
        free = (meminfo['MemFree'] || 0) + (meminfo['Buffers'] || 0) + (meminfo['Cached'] || 0)
        used = total - free
        color("RAM Usage:", 36) + " #{color(human_bytes(used), 33)} / #{color(human_bytes(total), 32)}"
    else
        color("RAM Usage:", 36) + " Info not available"
    end
end

def storage_info
    begin
        require 'sys/filesystem'
        stat = Sys::Filesystem.stat(Dir.pwd)
        total = stat.bytes_total
        free = stat.bytes_available
        used = total - free
        color("Storage Usage (#{Dir.pwd}):", 36) + " #{color(human_bytes(used), 33)} / #{color(human_bytes(total), 32)}"
    rescue LoadError
        color("Install 'sys-filesystem' gem for storage info:", 31) + " #{color('gem install sys-filesystem', 33)}"
    rescue
        color("Storage Usage:", 36) + " Info not available"
    end
end

def current_time
    Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")
end

def detect_distro
    if File.exist?('/etc/os-release')
        content = File.read('/etc/os-release')
        line = content.lines.find { |l| l.start_with?("PRETTY_NAME=") }
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

def read_cpu_times
    return [] unless File.exist?('/proc/stat')
    cpu_line = File.readlines('/proc/stat').find { |line| line.start_with?('cpu ') }
    return [] unless cpu_line
    cpu_line.split[1..-1].map(&:to_i)
end

def calculate_cpu_usage(prev, current)
    return 0.0 if prev.empty? || current.empty?

    prev_idle = prev[3] + (prev[4] || 0)
    idle = current[3] + (current[4] || 0)
    prev_non_idle = prev[0] + prev[1] + prev[2] + (prev[5] || 0) + (prev[6] || 0) + (prev[7] || 0)
    non_idle = current[0] + current[1] + current[2] + (current[5] || 0) + (current[6] || 0) + (current[7] || 0)
    prev_total = prev_idle + prev_non_idle
    total = idle + non_idle

    totald = total - prev_total
    idled = idle - prev_idle

    return 0.0 if totald <= 0
    ((totald - idled).to_f / totald) * 100
end

def cpu_cores_and_freq
    return [0, []] unless File.exist?('/proc/cpuinfo')
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
        sleep(0.1)
        current = read_cpu_times
        usage = calculate_cpu_usage(prev, current).round(1)
        cores, freqs = cpu_cores_and_freq
        freq_display = freqs.empty? ? "N/A" : freqs.map { |f| "#{f.round(0)}MHz" }.join(', ')

        color("CPU Usage:", 36) + " #{color("#{usage}%", 33)} | " +
                color("Cores:", 36) + " #{color(cores.to_s, 32)} | " +
                color("Freqs:", 36) + " #{color(freq_display, 35)}"
    end

    # This method will execute commands purely by forking and exec-ing
    # no intermediate sh/bash wrapper, args are passed directly to exec
    def run_single_command(cmd)
        cmd = expand_vars(cmd.strip)
        cmd, stdin_file, stdout_file, append = parse_redirection(cmd)
        args = Shellwords.shellsplit(cmd)
        return if args.empty?

        # built-in commands implemented here
        case args[0]
        when 'cd'
            path = args[1] || ENV['HOME']
            begin
                Dir.chdir(File.expand_path(path))
            rescue Errno::ENOENT
                puts color("cd: no such file or directory: #{path}", 31)
            end
            return
        when 'exit', 'quit'
            puts color("Bye!", 36)
            exit 0
        end


        Signal.trap("INT", "IGNORE")
        pid = fork do
            Signal.trap("INT", "DEFAULT")
            begin
                STDIN.reopen(File.open(stdin_file, 'r')) if stdin_file
            rescue; end
                begin
                    STDOUT.reopen(File.open(stdout_file, append ? 'a' : 'w')) if stdout_file
                rescue; end


                    begin
                        exec(*args)
                    rescue Errno::ENOENT, SystemCallError
                        puts color("Command not found: #{args[0]}", random_rainbow_color)
                        exit 127
                    end
                end
                Process.wait(pid)
                Signal.trap("INT") { puts }
            end

            def run_pipeline(commands, background)
                procs = []
                prev_read = nil
                Signal.trap("INT", "IGNORE")

                commands.each_with_index do |cmd, i|
                    cmd = expand_vars(cmd.strip)
                    cmd, stdin_file, stdout_file, append = parse_redirection(cmd)
                    args = Shellwords.shellsplit(cmd)
                    next if args.empty?

                    read_pipe, write_pipe = IO.pipe unless i == commands.size - 1

                    pid = fork do
                        Signal.trap("INT", "DEFAULT")
                        STDIN.reopen(prev_read) if prev_read
                        begin
                            STDIN.reopen(File.open(stdin_file, 'r')) if stdin_file
                        rescue; end

                            if i < commands.size - 1
                                STDOUT.reopen(write_pipe)
                            else
                                begin
                                    STDOUT.reopen(File.open(stdout_file, append ? 'a' : 'w')) if stdout_file
                                rescue; end
                                end

                                [prev_read, read_pipe, write_pipe].compact.each(&:close)

                                begin
                                    exec(*args)
                                rescue Errno::ENOENT, SystemCallError
                                    puts color("Command not found: #{args[0]}", random_rainbow_color)
                                    exit 127
                                end
                            end

                            [prev_read, write_pipe].compact.each(&:close)
                            prev_read = read_pipe
                            procs << pid
                        end

                        if background
                            Process.detach(procs.last)
                        else
                            procs.each { |pid| Process.wait(pid) }
                        end
                        Signal.trap("INT") { puts }
                    end

                    def print_welcome
                        puts color("Welcome to srsh - your simple Ruby shell!", 36)
                        puts color("Current Time:", 36) + " #{color(current_time, 34)}"
                        puts cpu_info
                        puts ram_info
                        puts storage_info
                        puts random_quote
                        puts
                        puts color("Coded with love by https://github.com/RobertFlexx", 90)
                        puts
                    end

                    print_welcome
                    hostname = Socket.gethostname
                    prompt_color = random_color_code

                    def prompt(hostname, prompt_color)
                        host_part = color(hostname, 36)
                        prompt_symbol = color(" > ", prompt_color)
                        "#{host_part}#{prompt_symbol}"
                    end

                    loop do
                        print "\033]0;srsh\007"
                        begin
                            input = Readline.readline(prompt(hostname, prompt_color), true)
                        rescue Interrupt
                            puts
                            next
                        end
                        break if input.nil?
                        input.strip!
                        next if input.empty?

                        if ['exit', 'quit'].include?(input)
                            print color("Do you really wanna leave me? (y/n) ", 35)
                            answer = $stdin.gets.chomp.downcase
                            if ['y', 'yes'].include?(answer)
                                puts color("Bye! Take care!", 36)
                                break
                            else
                                next
                            end
                        end

                        background = input.end_with?('&')
                        input.chomp!('&') if background
                        pipeline = input.split('|')
                        run_pipeline(pipeline, background)
                    end
