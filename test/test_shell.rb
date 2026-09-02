require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'fileutils'
require 'pty'
require 'timeout'
require 'srsh'

class SrshTestTTY < StringIO
  def tty? = true
end


class SrshShellTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-shell-test')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_connectors
    @app.executor.execute_line('put first && false || put recovered')
    assert_equal "first\nrecovered\n", @out.string
  end

  def test_alias
    @app.state.aliases['hi'] = 'put hello'
    @app.executor.execute_line('hi')
    assert_equal "hello\n", @out.string
  end

  def test_local_visible_to_shell_command
    nodes = Srsh::Language::ProgramParser.new("name := \"gang\"\nput $name\n").parse
    @app.executor.run_program(nodes)
    assert_equal "gang\n", @out.string
  end

  def test_pipeline_external
    skip 'printf/tr not available' unless @app.executor.find_executable('printf') && @app.executor.find_executable('tr')
    path = File.join(@dir, 'out.txt')
    @app.executor.execute_line("printf hello | tr a-z A-Z > #{Shellwords.escape(path)}")
    assert_equal 'HELLO', File.read(path)
  end

  def test_command_substitution_runs_through_srsh
    @app.executor.execute_line('put $(put nested)')
    assert_equal "nested\n", @out.string
  end

  def test_redirection
    path = File.join(@dir, 'hello.txt')
    @app.executor.execute_line("put hello > #{Shellwords.escape(path)}")
    assert_equal "hello\n", File.read(path)
  end

  def test_themes_alias_lists_themes
    @app.executor.execute_line('themes')
    assert_includes @out.string.lines.map(&:chomp), 'classic'
    assert_includes @out.string.lines.map(&:chomp), 'ocean'
  end

  def test_theme_alias_changes_scheme
    assert_equal 0, @app.executor.execute_line('theme ocean')
    assert_equal 'ocean', @app.theme.name
  end

  def test_background_job_refresh_is_portable
    skip 'sleep not available' unless @app.executor.find_executable('sleep')
    assert_equal 0, @app.executor.execute_line('sleep 0.02 &')
    sleep 0.08
    @app.state.prune_jobs!
    job = @app.state.jobs.last
    refute_nil job
    assert job.done?
  end
end

class SrshJobPortabilityTest < Minitest::Test
  def test_wait_flags_only_use_constants_available_on_this_ruby
    expected = Process::WNOHANG | Process::WUNTRACED
    expected |= Process.const_get(:WCONTINUED) if Process.const_defined?(:WCONTINUED)
    assert_equal expected, Srsh::Shell::Job::WAIT_FLAGS
  end

  def test_refresh_does_not_wait_again_for_done_job
    job = Srsh::Shell::Job.new(pgid: 123, pids: [456], command: 'done', background: false)
    job.instance_variable_set(:@status, :done)
    assert_same job, job.refresh!
    assert job.done?
  end
end

class SrshCompatibilityAndEditorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-compat-test')
    FileUtils.mkdir_p(File.join(@dir, '.srsh'))
    File.write(File.join(@dir, '.srsh_history'), "git status\nthemes --list\n")
    File.write(File.join(@dir, '.srsh', 'history'), "git status\nmake test\n")
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_original_history_path_is_canonical_and_v1_history_is_imported
    assert_equal File.join(@dir, '.srsh_history'), @app.paths.history
    assert_equal ['themes --list', 'git status', 'make test'], @app.history.to_a.last(3)
  end

  def test_neon_theme_from_original_shell_exists
    assert_includes @app.theme.names, 'neon'
  end

  def test_editor_ghost_renderer_moves_terminal_cursor_back_over_ghost
    # Reproduce an actual terminal destination so the ghost is ANSI-painted.
    # The old test depended on whether the process running Minitest happened
    # to own a TTY, which made `make` pass in CI and fail in a real terminal.
    output = SrshTestTTY.new
    editor = Srsh::Editor.new(@app, input: StringIO.new, output: output)
    editor.send(:render, 'p> ', %w[t h e], 3)

    raw = output.string
    visible = raw.gsub(Srsh::Editor::ANSI_RE, '').delete_prefix("\r")
    assert_equal 'p> themes --list', visible

    # "themes --list" minus "the" is ten visible characters.
    assert_match(/\e\[10D\z/, raw)
  end

  def test_bracketed_paste_normalizes_crlf_without_losing_newlines
    editor = Srsh::Editor.new(@app, input: StringIO.new, output: StringIO.new)
    assert_equal "a\nb\n", editor.send(:normalize_paste, "a\r\nb\r")
  end

  def test_multiline_history_is_recorded_as_physical_lines
    @app.send(:record_history, "x := [\n  1,\n  2\n]")
    assert_equal ['x := [', '  1,', '  2', ']'], @app.history.to_a.last(4)
  end

  def test_latest_history_prefix_is_used_for_prediction
    @app.history.add('git diff')
    @app.history.add('git log')
    editor = Srsh::Editor.new(@app, input: StringIO.new, output: StringIO.new)
    assert_equal 'git log', editor.send(:ghost_for, 'git l')
  end

  def test_escaped_dollar_is_literal
    ENV['SRSH_ESC_TEST'] = 'expanded'
    @app.executor.execute_line('put \\$SRSH_ESC_TEST')
    assert_equal "$SRSH_ESC_TEST\n", @out.string
  ensure
    ENV.delete('SRSH_ESC_TEST')
  end

  def test_trailing_logical_connector_is_parse_error
    assert_equal 2, @app.executor.execute_line('put ok &&')
    assert_match(/missing command after &&/, @err.string)
  end
end

class SrshJobHousekeepingContainmentTest < Minitest::Test
  BrokenJob = Struct.new(:id, :notified) do
    def done? = false
    def refresh! = raise(NameError, 'simulated platform wait bug')
  end

  def test_job_refresh_bug_does_not_take_down_shell_state
    state = Srsh::State.new
    state.jobs << BrokenJob.new(9, false)
    _out, err = capture_io { state.prune_jobs! }
    assert_match(/job refresh failed/, err)
    assert_equal 1, state.jobs.length
  end
end

class SrshReloadAndHistoryRegressionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-reload-test')
    FileUtils.mkdir_p(File.join(@dir, '.srsh'))
    File.write(File.join(@dir, '.srsh_history'), "old one\n")
    File.write(File.join(@dir, '.srsh', 'history'), "v1 one\n")
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_clear_history_does_not_reimport_v1_history_next_launch
    @app.history.clear
    app2 = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    assert_empty app2.history.to_a
  end

  def test_reset_dynamic_restores_overridden_core_builtin
    @app.builtins.register('true') { |_args| 99 }
    assert_equal 99, @app.builtins.call('true', ['true'])
    @app.builtins.reset_dynamic!
    assert_equal 0, @app.builtins.call('true', ['true'])
  end

  def test_theme_reset_removes_plugin_only_theme
    @app.theme.register('plugin-theme', path: '31')
    assert_includes @app.theme.names, 'plugin-theme'
    @app.theme.reset_dynamic!
    refute_includes @app.theme.names, 'plugin-theme'
  end
end

class SrshProductionRegressionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-production-regression')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_option_heavy_ls_uses_normal_external_executor
    skip 'external ls not available' unless @app.executor.find_executable('ls')
    path = File.join(@dir, 'ls.txt')
    status = @app.executor.execute_line("ls -d . > #{Shellwords.escape(path)}")
    assert_equal 0, status
    assert_equal ".\n", File.read(path)
  end

  def test_history_loading_is_bounded_to_configured_max
    history = File.join(@dir, '.srsh_history')
    File.open(history, 'w') { |f| 6_100.times { |i| f.puts("cmd-#{i}") } }
    app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    assert_equal Srsh::History::DEFAULT_MAX, app.history.length
    assert_equal 'cmd-6099', app.history.to_a.last
  end
end

class SrshInteractiveLanguageRoutingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-input-routing')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_hot_rsh_lines_run_directly_at_shell_input_boundary
    @app.run_input('x := 21')
    @app.run_input('= x * 2')
    @app.run_input('? x > 10 => = "big"')
    assert_equal "42\nbig\n", @out.string
  end

  def test_normal_command_is_still_a_shell_command
    @app.run_input('put shell')
    assert_equal "shell\n", @out.string
  end

  def test_multiline_rsh_can_use_same_input_router
    @app.run_input("fn twice(x)\n  return x * 2\nend\n")
    @app.run_input('= twice(8)')
    assert_equal "16\n", @out.string
  end
end

class SrshLanguageCompletionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-completion')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @editor = Srsh::Editor.new(@app, input: StringIO.new, output: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_readable_language_forms_participate_in_first_word_completion
    completions = @editor.send(:tab_completions_for, 'pro', 'pro', true)
    assert_includes completions, 'proto'
  end

  def test_prototypes_and_traits_participate_in_first_word_completion
    @app.state.prototypes['Project'] = {}
    @app.state.traits['Printable'] = {}
    assert_includes @editor.send(:tab_completions_for, 'Proj', 'Proj', true), 'Project'
    assert_includes @editor.send(:tab_completions_for, 'Print', 'Print', true), 'Printable'
  end
end

class SrshOnePointZeroShellTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-1.0-shell')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_repl_completeness_recognizes_multiline_collection
    assert @app.send(:incomplete_input?, 'jobs := [')
    refute @app.send(:incomplete_input?, "jobs := [\n1,\n2\n]")
  end

  def test_repl_completeness_recognizes_shell_pipeline_continuation
    assert @app.send(:incomplete_input?, 'printf hi |')
    refute @app.send(:incomplete_input?, 'printf hi | cat')
  end

  def test_pipefail_option_returns_nonzero_pipeline_stage
    skip 'true/false missing' unless @app.executor.find_executable('true') && @app.executor.find_executable('false')
    @app.state.options['pipefail'] = true
    assert_equal 1, @app.executor.execute_line('false | true')
  end

  def test_nounset_rejects_missing_shell_variable
    @app.state.options['nounset'] = true
    assert_raises(Srsh::RuntimeError) { @app.executor.execute_line('put $THIS_SRSH_NAME_DOES_NOT_EXIST') }
  end

  def test_wait_builtin_can_reap_background_job
    skip 'true missing' unless @app.executor.find_executable('true')
    assert_equal 0, @app.executor.execute_line('true &')
    assert_equal 0, @app.builtins.call('wait', ['wait', '%1'])
  end

  def test_noclobber_refuses_existing_target
    path = File.join(@dir, 'keep.txt')
    File.write(path, 'old')
    @app.state.options['noclobber'] = true
    assert_equal 1, @app.executor.execute_line("put new > #{Shellwords.escape(path)}")
    assert_equal 'old', File.read(path)
  end
end

class SrshGlobbingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-glob')
    @out = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: StringIO.new)
    File.write(File.join(@dir, 'a.log'), '')
    File.write(File.join(@dir, 'b.log'), '')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_unquoted_wildcard_expands_but_quoted_wildcard_does_not
    Dir.chdir(@dir) do
      assert_equal %w[a.log b.log], @app.executor.send(:expand_command_word, '*.log')
      assert_equal ['*.log'], @app.executor.send(:expand_command_word, '"*.log"')
      assert_equal ['*.log'], @app.executor.send(:expand_command_word, '\\*.log')
    end
  end

  def test_tilde_expands_to_shell_home
    assert_equal [@dir], @app.executor.send(:expand_command_word, '~')
  end
end

class SrshBracketedPastePTYTest < Minitest::Test
  def read_until(io, needle, timeout: 5)
    data = +''
    Timeout.timeout(timeout) do
      loop do
        data << io.readpartial(4096)
        return data if data.include?(needle)
      end
    end
  end

  def test_multiline_paste_is_one_program_and_waits_for_confirmation
    home = Dir.mktmpdir('srsh-paste-pty')
    bin = File.expand_path('../bin/srsh', __dir__)
    program = <<~RSH
      value := 220
      match value
      | 220 =>
        = "paste-ok"
      | _ =>
        = "bad"
      end
    RSH

    reader = writer = nil
    pid = nil
    begin
      reader, writer, pid = PTY.spawn({ 'HOME' => home, 'TERM' => 'xterm-256color' }, bin, '--norc')
      startup = read_until(reader, ' > ')
      assert_includes startup, "\e[?2004h"

      writer.write("\e[200~#{program}\e[201~")
      preview = read_until(reader, 'Enter to run, Ctrl-C to cancel]')
      assert_includes preview, '[pasted 7 lines:'
      refute_includes preview, 'paste-ok\r\n'

      writer.write("\r")
      executed = read_until(reader, 'paste-ok')
      assert_includes executed, 'paste-ok'

      # Wait for the *next* editor read before asking the shell to exit.
      # Otherwise the command can race with the program that is still printing.
      read_until(reader, ' > ') unless executed.include?(' > ')
      writer.write("exit\r")
      status = nil
      Timeout.timeout(5) do
        _, status = Process.wait2(pid)
      end
      pid = nil
      assert_equal 0, status.exitstatus
    rescue NotImplementedError, Errno::ENOSYS
      skip 'PTY support unavailable'
    ensure
      if pid
        Process.kill('KILL', pid) rescue nil
        Process.wait(pid) rescue nil
      end
      reader&.close rescue nil
      writer&.close rescue nil
      FileUtils.remove_entry(home) if home && File.exist?(home)
    end
  end
end
