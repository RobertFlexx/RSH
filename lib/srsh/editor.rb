require 'io/console'

module Srsh
  class Editor
    ANSI_RE = /\e\[[0-9;?]*[ -\/]*[@-~]/
    EXEC_CACHE_TTL = 2.5
    BRACKETED_PASTE_START = '[200~'.freeze
    BRACKETED_PASTE_END = "\e[201~".freeze
    MAX_PASTE_BYTES = 4 * 1024 * 1024
    LANGUAGE_WORDS = %w[if else end each while fn task proto trait slot space use defer bridge try catch finally match code emit return break continue].freeze

    def initialize(app, input: STDIN, output: STDOUT)
      @app = app
      @history = app.history
      @input = input
      @output = output
      @render_rows = 0
      @exec_path = nil
      @exec_entries = []
      @exec_built_at = 0.0
    end

    def read(prompt)
      return fallback(prompt) unless interactive_console?

      chars = []
      cursor = 0
      hist_index = @history.length
      saved_line = []
      last_tab_prefix = nil
      @render_rows = 0

      paste_mode = false
      console.raw do |io|
        enable_bracketed_paste
        paste_mode = true
        render(prompt, chars, cursor)
        loop do
          ch = io.getch

          case ch
          when "\r", "\n"
            cursor = chars.length
            render(prompt, chars, cursor, show_ghost: false)
            @output.print "\r\n"
            @output.flush
            return chars.join
          when "\u0003" # Ctrl-C
            render(prompt, chars, cursor, show_ghost: false)
            @output.print "^C\r\n"
            @output.flush
            @app.state.last_status = 130
            return :interrupt
          when "\u0004" # Ctrl-D
            if chars.empty?
              clear_render
              @output.print "\r\n"
              @output.flush
              return :eof
            end
          when "\u0001" # Ctrl-A
            cursor = 0
            last_tab_prefix = nil
          when "\u0005" # Ctrl-E
            cursor = chars.length
            last_tab_prefix = nil
          when "\u000b" # Ctrl-K
            chars.slice!(cursor..)
            last_tab_prefix = nil
          when "\u0015" # Ctrl-U
            chars.slice!(0...cursor)
            cursor = 0
            last_tab_prefix = nil
          when "\u0017" # Ctrl-W
            while cursor.positive? && whitespace?(chars[cursor - 1])
              chars.delete_at(cursor -= 1)
            end
            while cursor.positive? && !whitespace?(chars[cursor - 1])
              chars.delete_at(cursor -= 1)
            end
            last_tab_prefix = nil
          when "\u000c" # Ctrl-L
            @output.print "\e[2J\e[H"
            @render_rows = 0
          when "\u007f", "\b"
            chars.delete_at(cursor -= 1) if cursor.positive?
            hist_index = @history.length
            last_tab_prefix = nil
          when "\t"
            chars, cursor, last_tab_prefix, printed = handle_tab_completion(prompt, chars, cursor, last_tab_prefix)
            @render_rows = 1 if printed
          when "\e"
            seq = read_escape(io)
            case seq
            when BRACKETED_PASTE_START
              pasted = read_bracketed_paste(io)
              pasted = normalize_paste(pasted)

              if pasted.include?("\n")
                before = chars[0...cursor].join
                after = chars[cursor..]&.join.to_s
                program = before + pasted + after
                action = confirm_multiline_paste(io, prompt, program)
                if action == :accept
                  @output.print "\r\n"
                  @output.flush
                  return program
                end

                chars = []
                cursor = 0
                hist_index = @history.length
                saved_line = []
                last_tab_prefix = nil
                @render_rows = 0
                render(prompt, chars, cursor)
                next
              end

              pasted.each_char do |char|
                chars.insert(cursor, char)
                cursor += 1
              end
              hist_index = @history.length
              last_tab_prefix = nil
            when '[A'
              if hist_index == @history.length
                saved_line = chars.dup
              end
              if hist_index.positive?
                hist_index -= 1
                chars = @history[hist_index].to_s.each_char.to_a
                cursor = chars.length
              end
            when '[B'
              if hist_index < @history.length - 1
                hist_index += 1
                chars = @history[hist_index].to_s.each_char.to_a
              elsif hist_index == @history.length - 1
                hist_index = @history.length
                chars = saved_line.dup
              end
              cursor = chars.length
            when '[C'
              if cursor < chars.length
                cursor += 1
              elsif (suggestion = ghost_for(chars.join))
                chars = suggestion.each_char.to_a
                cursor = chars.length
              end
            when '[D'
              cursor -= 1 if cursor.positive?
            when '[H', 'OH', '[1~', '[7~'
              cursor = 0
            when '[F', 'OF', '[4~', '[8~'
              cursor = chars.length
            when '[3~'
              chars.delete_at(cursor) if cursor < chars.length
            end
            last_tab_prefix = nil
          else
            if printable?(ch)
              ch.each_char do |char|
                chars.insert(cursor, char)
                cursor += 1
              end
              hist_index = @history.length
              last_tab_prefix = nil
            end
          end

          render(prompt, chars, cursor)
        end
      end
    rescue Errno::EIO, IOError
      fallback(prompt)
    ensure
      disable_bracketed_paste if paste_mode
      @render_rows = 0
    end

    private

    def console
      IO.console
    end

    def interactive_console?
      @input.equal?(STDIN) && @output.equal?(STDOUT) && STDIN.tty? && STDOUT.tty? && console
    end

    def fallback(prompt)
      @output.print prompt
      @output.flush
      line = @input.gets
      line ? line.chomp : :eof
    end

    def printable?(ch)
      return false if ch.nil? || ch.empty?
      ch.each_codepoint.all? { |cp| cp >= 32 && cp != 127 }
    rescue ArgumentError
      false
    end

    def whitespace?(ch)
      ch && ch.match?(/\s/)
    end

    def enable_bracketed_paste
      @output.print "\e[?2004h"
      @output.flush
    end

    def disable_bracketed_paste
      @output.print "\e[?2004l"
      @output.flush
    rescue IOError, SystemCallError
      nil
    end

    def normalize_paste(text)
      text.to_s.gsub("\r\n", "\n").tr("\r", "\n")
    end

    # Bracketed paste gives us a hard boundary around clipboard input.  Keep
    # reading until the terminal's end marker instead of letting embedded
    # newlines masquerade as Enter key presses.
    def read_bracketed_paste(io)
      data = +''
      loop do
        ch = io.getch
        raise IOError, 'paste ended unexpectedly' unless ch
        data << ch
        if data.end_with?(BRACKETED_PASTE_END)
          data.delete_suffix!(BRACKETED_PASTE_END)
          return data
        end
        raise Error, 'pasted input is too large' if data.bytesize > MAX_PASTE_BYTES
      end
    end

    def confirm_multiline_paste(io, prompt, program)
      lines = program.lines.count
      first = program.lines.find { |line| !line.strip.empty? }.to_s.strip
      first = first.each_char.take(44).join + (first.each_char.count > 44 ? '…' : '')

      clear_render
      message = "[pasted #{lines} lines"
      message << ": #{first}" unless first.empty?
      message << ': Enter to run, Ctrl-C to cancel]'
      @output.print "\r", prompt, @app.theme.paint(message, :dim, io: @output)
      @output.flush
      @render_rows = [(visible_length(prompt) + visible_length(message)).fdiv(terminal_width).ceil, 1].max

      loop do
        ch = io.getch
        case ch
        when "\r", "\n"
          clear_render
          @output.print "\r", prompt, @app.theme.paint("[running pasted #{lines}-line program]", :dim, io: @output)
          @output.flush
          @render_rows = 1
          return :accept
        when "\u0003", "\e"
          clear_render
          @output.print "\r", prompt, @app.theme.paint('[paste cancelled]', :dim, io: @output), "\r\n"
          @output.flush
          @app.state.last_status = 130 if ch == "\u0003"
          @render_rows = 0
          return :cancel
        end
      end
    end

    # ESC can arrive before the rest of a CSI sequence. Waiting a tiny bounded
    # amount avoids both the old permanent block on a lone Escape key and the
    # rewrite's race where arrow-key bytes were often missed entirely.
    def read_escape(io)
      out = +''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.04
      while out.bytesize < 12
        remain = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remain <= 0
        break unless IO.select([io], nil, nil, remain)
        c = io.getch
        break unless c
        out << c
        break if escape_sequence_complete?(out)
      end
      out
    rescue IOError, SystemCallError
      out || ''
    end

    def escape_sequence_complete?(seq)
      return true if seq.start_with?('O') && seq.length >= 2 && seq[-1].match?(/[A-Za-z]/)
      return false unless seq.start_with?('[')
      !!(seq =~ /\A\[[0-9;?]*[A-Za-z~]\z/)
    end

    def ghost_for(prefix)
      return nil if prefix.nil? || prefix.empty?
      @history.reverse_each do |line|
        next if line.nil? || line.empty?
        next if line.start_with?('[completions:')
        next unless line.start_with?(prefix)
        next if line == prefix
        return line
      end
      nil
    end

    def render(prompt, chars, cursor, show_ghost: true)
      chars ||= []
      cursor = [[cursor, 0].max, chars.length].min
      text = chars.join
      ghost_tail = ''

      if show_ghost && cursor == chars.length
        suggestion = ghost_for(text)
        ghost_tail = suggestion ? suggestion.each_char.to_a[chars.length..]&.join.to_s : ''
      end

      prompt_vis = visible_length(prompt)
      text_vis = visible_length(text)
      ghost_vis = visible_length(ghost_tail)
      total_vis = prompt_vis + text_vis + ghost_vis
      width = terminal_width
      rows = [(total_vis.to_f / width).ceil, 1].max

      clear_render
      @output.print "\r", prompt, text
      @output.print @app.theme.paint(ghost_tail, :dim, io: @output) unless ghost_tail.empty?

      # Critical old-SRSH behavior: the ghost is painted *after* the logical
      # cursor, so move back across both it and any real text to the cursor's
      # right. Without the ghost length the terminal cursor lies to the user.
      real_tail_vis = visible_length(chars[cursor..]&.join.to_s)
      move_left = ghost_vis + real_tail_vis
      @output.print "\e[#{move_left}D" if move_left.positive?
      @output.flush
      @render_rows = rows
    end

    def clear_render
      return unless @render_rows.positive?
      @output.print "\r"
      (@render_rows - 1).times { @output.print "\e[1A\r" }
      @render_rows.times do |i|
        @output.print "\e[0K"
        @output.print "\n" if i < @render_rows - 1
      end
      (@render_rows - 1).times { @output.print "\e[1A\r" }
    end

    def terminal_width
      width = begin
        if console
          console.winsize[1]
        else
          Integer(ENV['COLUMNS'], exception: false)
        end
      rescue SystemCallError, IOError
        nil
      end
      width = 80 unless width && width.positive?
      [width, 20].max
    end

    def visible_length(text)
      text.to_s.gsub(ANSI_RE, '').each_char.count
    end

    def handle_tab_completion(prompt, chars, cursor, last_tab_prefix)
      buffer = chars.join
      cursor = [[cursor, 0].max, chars.length].min
      char_prefix = chars[0...cursor].join
      match = char_prefix.rindex(/[ \t]/)
      byte_start = match ? match + 1 : 0
      prefix = char_prefix[byte_start..].to_s
      word_start_chars = char_prefix[0...byte_start].each_char.count

      before_word = chars[0...word_start_chars].join
      at_first_word = before_word.strip.empty?
      first_word = buffer.strip.split(/\s+/, 2)[0].to_s
      completions = tab_completions_for(prefix, first_word, at_first_word)
      return [chars, cursor, nil, false] if completions.empty?

      if completions.length == 1
        replacement = completions.first.each_char.to_a
        chars[word_start_chars...cursor] = replacement
        return [chars, word_start_chars + replacement.length, nil, true]
      end

      if prefix != last_tab_prefix
        common = longest_common_prefix(completions)
        if common.length > prefix.length
          replacement = common.each_char.to_a
          chars[word_start_chars...cursor] = replacement
          cursor = word_start_chars + replacement.length
        else
          @output.print "\a"
          @output.flush
        end
        return [chars, cursor, prefix, false]
      end

      render(prompt, chars, cursor, show_ghost: false)
      print_tab_list(completions)
      [chars, cursor, prefix, true]
    end

    def tab_completions_for(prefix, first_word, at_first_word)
      prefix ||= ''
      file_completions = path_completions(prefix, first_word)
      exec_completions = []

      if first_word != 'cat' && first_word != 'cd' && at_first_word && !prefix.include?('/')
        names = @app.builtins.names + @app.state.functions.keys + @app.state.prototypes.keys +
                @app.state.traits.keys + @app.state.aliases.keys + LANGUAGE_WORDS + executable_names
        exec_completions = names.grep(/^#{Regexp.escape(prefix)}/)
      end

      (file_completions + exec_completions).uniq.sort
    end

    def path_completions(prefix, first_word)
      dir = '.'
      base = prefix

      if prefix.include?('/')
        if prefix.end_with?('/')
          dir = prefix == '/' ? '/' : prefix.chomp('/')
          base = ''
        else
          dir = File.dirname(prefix)
          base = File.basename(prefix)
        end
        dir = '.' if dir.nil? || dir.empty?
      end

      lookup_dir = expand_completion_dir(dir)
      return [] unless Dir.exist?(lookup_dir)

      Dir.children(lookup_dir).filter_map do |entry|
        next unless entry.start_with?(base)
        full = File.join(lookup_dir, entry)
        shown = dir == '.' ? entry : File.join(File.dirname(prefix), entry)

        case first_word
        when 'cd'
          next unless File.directory?(full)
          shown.end_with?('/') ? shown : "#{shown}/"
        when 'cat'
          File.file?(full) ? shown : nil
        else
          File.directory?(full) && !shown.end_with?('/') ? "#{shown}/" : shown
        end
      end
    rescue SystemCallError
      []
    end

    def expand_completion_dir(dir)
      return @app.paths.home if dir == '~'
      return File.join(@app.paths.home, dir[2..]) if dir.start_with?('~/')
      File.expand_path(dir)
    end

    def executable_names
      path = ENV['PATH'].to_s
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @exec_path != path || now - @exec_built_at > EXEC_CACHE_TTL
        @exec_path = path
        @exec_built_at = now
        @exec_entries = []
        path.split(File::PATH_SEPARATOR).each do |dir|
          dir = '.' if dir.nil? || dir.empty?
          begin
            Dir.children(dir).each do |entry|
              full = File.join(dir, entry)
              @exec_entries << entry if File.file?(full) && File.executable?(full)
            end
          rescue SystemCallError
            next
          end
        end
        @exec_entries.uniq!
      end
      @exec_entries
    end

    def longest_common_prefix(strings)
      return '' if strings.empty?
      shortest = strings.min_by { |s| s.each_char.count }.to_s.each_char.to_a
      shortest.length.times do |i|
        c = shortest[i]
        strings.each do |s|
          chars = s.each_char.to_a
          return shortest[0...i].join if chars[i] != c
        end
      end
      shortest.join
    end

    def print_tab_list(completions)
      return if completions.empty?
      width = terminal_width
      max_len = completions.map { |s| visible_length(s) }.max || 0
      col_width = [max_len + 2, 4].max
      cols = [width / col_width, 1].max
      rows = (completions.length.to_f / cols).ceil

      @output.print "\r\n"
      rows.times do |row|
        line = +''
        cols.times do |col|
          index = col * rows + row
          break if index >= completions.length
          item = completions[index]
          line << item << (' ' * [col_width - visible_length(item), 0].max)
        end
        @output.print "\r", line.rstrip, "\n"
      end
      @output.print "\r\n"
      @output.flush
    end
  end
end
