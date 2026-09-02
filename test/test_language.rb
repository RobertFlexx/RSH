require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'srsh'

class SrshLanguageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-test')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_arithmetic_and_precedence
    assert_equal 7, @eval.parse_eval('1 + 2 * 3')
    assert_equal 9, @eval.parse_eval('(1 + 2) * 3')
    assert_equal 256, @eval.parse_eval('2 ** 8')
  end

  def test_literals_collections_and_ranges
    assert_equal [1, 2, 3], @eval.parse_eval('[1, 2, 3]')
    assert_equal({ 'name' => 'srsh', 'ok' => true }, @eval.parse_eval('%[name: "srsh", ok: yes]'))
    assert_equal (1...4), @eval.parse_eval('1 ..< 4')
    assert_equal 'raw\\ntext', @eval.parse_eval('[[raw\\ntext]]')
  end

  def test_boolean_membership_and_regex
    assert_equal true, @eval.parse_eval('2 in [1,2,3]')
    assert_equal true, @eval.parse_eval('"ruby" =~ "^ru"')
    assert_equal 'fallback', @eval.parse_eval('void ?? "fallback"')
  end

  def test_program_blocks_and_functions
    script = <<~RSH
      name := "Robert"
      values := [2, 4, 6]
      ? len(values) == 3
        emit "ok " ++ name
      :?
        emit "bad"
      .?

      :: twice(x)
        ^ int(x) * 2
      .::

      @ 3 -> i
        emit twice(i)
      .@
    RSH
    nodes = Srsh::Language::ProgramParser.new(script).parse
    @app.executor.run_program(nodes)
    assert_equal "ok Robert\n0\n2\n4\n", @out.string
  end

  def test_match
    script = <<~RSH
      os := "linux"
      ?? os
      | "darwin" ->
        emit "mac"
      | "linux" ->
        emit "penguin"
      | _ ->
        emit "other"
      .??
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(script).parse)
    assert_equal "penguin\n", @out.string
  end

  def test_bad_string_reports_parse_error
    error = assert_raises(Srsh::ParseError) { @eval.parse_eval('"oops') }
    assert_match(/unterminated string/, error.message)
  end
end

class SrshLanguageHardeningTest < Minitest::Test
  def test_symbolic_break_and_next_are_not_parsed_as_returns
    nodes = Srsh::Language::ProgramParser.new("@ 2 -> i\n^>\n.@\n@ 2 -> i\n^!\n.@\n").parse
    assert_instance_of Srsh::Language::NextNode, nodes[0].body[0]
    assert_instance_of Srsh::Language::BreakNode, nodes[1].body[0]
  end

  def test_unclosed_match_is_rejected
    error = assert_raises(Srsh::ParseError) do
      Srsh::Language::ProgramParser.new("?? 1\n| 1 ->\n  emit \"x\"\n").parse
    end
    assert_match(/unclosed \?\? block/, error.message)
  end

  def test_check_phase_validates_expressions
    assert_raises(Srsh::ParseError) do
      Srsh::Language::ProgramParser.new("value := (1 + )\n").parse
    end
  end

  def test_invalid_base_digit_is_rejected
    error = assert_raises(Srsh::ParseError) { Srsh::Language::ExprParser.new('0b102').parse }
    assert_match(/invalid digit/, error.message)
  end

  def test_expression_nesting_is_bounded
    text = ('(' * 300) + '1' + (')' * 300)
    error = assert_raises(Srsh::ParseError) { Srsh::Language::ExprParser.new(text).parse }
    assert_match(/nesting too deep/, error.message)
  end
end

class SrshLanguageRegressionExtrasTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-lang-extra')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_function_defaults_can_contain_commas_and_nested_collections
    script = <<~RSH
      :: count(x := [1, 2, 3], opts := %[a: 1, b: 2])
        ^ len(x) + len(opts)
      .::
      emit count()
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(script).parse)
    assert_equal "5\n", @out.string
  end

  def test_hash_member_preserves_false_value
    assert_equal false, @eval.parse_eval('%[enabled: no].enabled')
  end

  def test_raw_string_hash_is_not_mistaken_for_comment
    nodes = Srsh::Language::ProgramParser.new("emit [[hello # still data]]\n").parse
    @app.executor.run_program(nodes)
    assert_equal "hello # still data\n", @out.string
  end

  def test_bad_numeric_underscore_is_rejected
    %w[1_ 1__2 0x_FF 1_e2].each do |source|
      assert_raises(Srsh::ParseError, source) { Srsh::Language::ExprParser.new(source).parse }
    end
  end
end

class SrshMatchRuntimeErrorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-match-runtime')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_match_pattern_runtime_errors_are_not_silently_skipped
    source = <<~RSH
      ?? 1
      | 1 / 0 ->
        emit "impossible"
      | _ ->
        emit "fallback"
      .??
    RSH
    nodes = Srsh::Language::ProgramParser.new(source).parse
    error = assert_raises(Srsh::RuntimeError) { @app.executor.run_program(nodes) }
    assert_match(/division by zero/, error.message)
  end
end


class SrshScopeAndMatchFormattingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-scope')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_binding_inside_callee_shadows_instead_of_mutating_caller
    source = <<~RSH
      :: inner()
        op := "inner"
        ^ 7
      .::
      :: outer()
        op := "outer"
        value := inner()
        emit op
        ^ value
      .::
      emit outer()
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "outer\n7\n", @out.string
  end

  def test_compound_assignment_still_updates_current_binding
    source = <<~RSH
      :: bump()
        n := 4
        n += 3
        ^ n
      .::
      emit bump()
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "7\n", @out.string
  end

  def test_match_allows_blank_and_comment_lines_before_first_arm
    source = <<~RSH
      value := 2
      ?? value

        # readable spacing is valid
      | 1 ->
        emit "one"
      | 2 ->
        emit "two"
      .??
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "two\n", @out.string
  end
end

class SrshHotLanguageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-hot')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_script(source)
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
  end

  def test_expression_pipeline_and_lambdas
    assert_equal [6, 12], @eval.parse_eval('[1,2,3,4] |> filter(::x => x % 2 == 0) |> map(::x => x * 3)')
    assert_equal 10, @eval.parse_eval('[1,2,3,4] |> sum')
  end

  def test_pipeline_can_target_user_function
    run_script("fn twice(x) => x * 2\n= 9 |> twice\n")
    assert_equal "18\n", @out.string
  end

  def test_interpolated_strings_use_full_expressions
    run_script(<<~'RSH')
      name := "srsh"
      = "#{name}:#{1 + 2}"
    RSH
    assert_equal "srsh:3
", @out.string
  end

  def test_safe_access
    assert_nil @eval.parse_eval('void?.missing')
    assert_nil @eval.parse_eval('void?[0]')
    assert_equal 7, @eval.parse_eval('%[a: %[b: 7]]?.a?.b')
  end

  def test_expression_command_capture
    assert_equal 'hello', @eval.parse_eval('$(printf hello)')
  end

  def test_readable_and_hot_inline_forms_share_semantics
    source = <<~RSH
      fn twice(x) => x * 2
      if yes => emit twice(3)
      each [1,2] -> n => emit n
      ? yes => emit "hot"
      @ [8,9] -> n => emit n
    RSH
    run_script(source)
    assert_equal "6\n1\n2\nhot\n8\n9\n", @out.string
  end

  def test_readable_match_and_inline_arms
    run_script("match 2\n| 1 => emit \"one\"\n| 2 => emit \"two\"\n| _ => emit \"other\"\nend\n")
    assert_equal "two\n", @out.string
  end


  def test_readable_match_allows_multiline_fat_arrow_arms
    run_script(<<~RSH)
      match 220
      | 220 =>
        emit "fat block"
      | _ =>
        emit "other"
      end
    RSH
    assert_equal "fat block\n", @out.string
  end

  def test_code_block_is_parsed_code_not_eager_execution
    source = <<~'RSH'
      who := "gang"
      code greeting
        emit "wsg #{who}"
      end
      = type(greeting)
      run(greeting)
    RSH
    run_script(source)
    assert_equal "code\nwsg gang\n", @out.string
  end

  def test_eval_and_dynamic_code
    run_script("x := 7\nformula := \"x * 3\"\n= eval(formula)\nrun(code(\"emit 11\"))\n")
    assert_equal "21\n11\n", @out.string
  end

  def test_function_rest_args_and_defaults_can_see_previous_params
    run_script("fn pack(head, *rest) => len(rest)\nfn scale(x, by := x) => x * by\n= pack(1,2,3,4)\n= scale(5)\n")
    assert_equal "3\n25\n", @out.string
  end

  def test_lambda_rest_args
    assert_equal 3, @eval.parse_eval('fold([1,2], 0, ::(acc, x, *rest) => acc + x)')
  end

  def test_meta_validation
    assert_equal true, @eval.parse_eval('valid("x := 1")')
    assert_equal false, @eval.parse_eval('valid("x := (")')
    assert_equal true, @eval.parse_eval('valid("1 + 2", "expr")')
  end
end

class SrshVerticalPipelineTest < Minitest::Test
  def test_value_pipeline_can_continue_on_following_lines
    source = <<~RSH
      result := [1,2,3,4]
        |> filter(::x => x > 2)
        |> map(::x => x * 10)
        |> sum
      = result
    RSH
    dir = Dir.mktmpdir('srsh-vertical')
    out = StringIO.new
    app = Srsh::App.new(home: dir, out: out, err: StringIO.new)
    app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "70\n", out.string
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end
end

class SrshPatternAndDestructureTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-patterns')
    @out = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_match_ranges_and_guards
    source = <<~RSH
      match 503
      | 200..299 => emit "ok"
      | ? it >= 500 => emit "server"
      | _ => emit "other"
      end
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "server\n", @out.string
  end

  def test_each_destructures_pairs
    source = <<~RSH
      each %[a: 1, b: 2] -> key, value
        = key ++ ":" ++ str(value)
      end
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "a:1\nb:2\n", @out.string
  end
end

class SrshSafeAccessSemanticsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-safe-access')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_normal_access_is_strict_but_safe_access_short_circuits
    assert_raises(Srsh::RuntimeError) { @eval.parse_eval('void.missing') }
    assert_nil @eval.parse_eval('void?.missing')
    assert_raises(Srsh::RuntimeError) { @eval.parse_eval('void[0]') }
    assert_nil @eval.parse_eval('void?[0]')
  end
end

class SrshPowerLanguageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-power')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_script(source)
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
  end

  def test_named_functions_are_first_class
    run_script <<~RSH
      fn square(x) => x * x
      = [1,2,3,4] |> map(square) |> sum
    RSH
    assert_equal "30\n", @out.string
  end

  def test_zero_arg_lambda_and_spawn_operator
    assert_equal 42, @eval.parse_eval('(&:: => 21 * 2).await()')
  end

  def test_prototype_slots_methods_and_mutation
    run_script <<~RSH
      proto Counter(start := 0)
        slot value := start
        fn inc(by := 1)
          self.value += by
          return self
        end
        fn read() => self.value
      end
      c := Counter(10)
      c.inc(5)
      = c.read()
      = fields(c)
    RSH
    assert_equal "15\n%[value: 15]\n", @out.string
  end

  def test_trait_composition
    run_script <<~RSH
      trait Named
        fn label() => "item=\#{self.name}"
      end
      proto Item(name) with Named
        slot name := name
      end
      x := Item("gear")
      = x.label()
    RSH
    assert_equal "item=gear\n", @out.string
  end

  def test_async_task_functions_start_immediately_and_join
    run_script <<~RSH
      task twice(x)
        sleep(0.005)
        return x * 2
      end
      jobs := [1,2,3,4] |> map(twice)
      = await_all(jobs)
    RSH
    assert_equal "[2, 4, 6, 8]\n", @out.string
  end

  def test_atom_is_safe_shared_state_for_tasks
    run_script <<~RSH
      total := atom(0)
      tasks := [1,2,3,4] |> map(::x => &:: => total.swap(::n => n + x))
      await_all(tasks)
      = total.get()
    RSH
    assert_equal "10\n", @out.string
  end

  def test_channels_move_values_between_tasks
    run_script <<~RSH
      ch := chan(1)
      producer := &:: => ch.send("hello")
      = ch.recv(1)
      = producer.await(1)
    RSH
    assert_equal "hello\nhello\n", @out.string
  end

  def test_parallel_thread_pool_preserves_input_order
    assert_equal [1, 4, 9, 16], @eval.parse_eval('parallel([1,2,3,4], ::x => x * x, 2)')
  end

  def test_pmap_uses_process_workers_and_preserves_order
    skip 'fork unavailable' unless Process.respond_to?(:fork)
    assert_equal [1, 8, 27, 64], @eval.parse_eval('pmap([1,2,3,4], ::x => x ** 3, 2)')
  end

  def test_method_style_functional_chains
    assert_equal 56, @eval.parse_eval('[1,2,3,4,5,6].filter(::x => x % 2 == 0).map(::x => x ** 2).sum()')
  end

  def test_destructuring_with_rest
    run_script <<~RSH
      a, b, *rest := [10,20,30,40]
      = a + b
      = rest
    RSH
    assert_equal "30\n[30, 40]\n", @out.string
  end

  def test_try_catch_finally
    run_script <<~RSH
      try
        fail("boom")
      catch err
        = err.message
      finally
        = "cleanup"
      end
    RSH
    assert_equal "boom\ncleanup\n", @out.string
  end

  def test_prototype_and_partial_map_patterns
    run_script <<~RSH
      proto Box(x)
        slot x := x
      end
      b := Box(3)
      match b
      | Box => = "box"
      | _ => = "no"
      end
      m := %[status: 200, body: "ok"]
      match m
      | %[status: 200] => = "ok"
      | _ => = "bad"
      end
    RSH
    assert_equal "box\nok\n", @out.string
  end
end

class SrshPowerLanguageIntegrationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-power-integration')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_script(source)
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
  end

  def test_async_function_captures_call_site_without_mutating_main_scope
    run_script <<~RSH
      scale := 3
      task calc(x)
        scale += 1
        return x * scale
      end
      = calc(2).await()
      = scale
    RSH
    assert_equal "8\n3\n", @out.string
  end

  def test_named_function_reference_keeps_context_in_parallel_workers
    run_script <<~RSH
      scale := 3
      fn mul(x) => x * scale
      = parallel([1,2,3,4], mul, 2)
    RSH
    assert_equal "[3, 6, 9, 12]\n", @out.string
  end

  def test_compound_object_slot_updates_are_atomic_across_tasks
    run_script <<~RSH
      proto Counter()
        slot value := 0
        fn inc()
          self.value += 1
        end
      end
      c := Counter()
      tasks := (0 ..< 40) |> map(::i => &:: => c.inc())
      await_all(tasks)
      = c.value
    RSH
    assert_equal "40\n", @out.string
  end

  def test_spaces_namespace_constants_functions_tasks_and_prototypes
    run_script <<~RSH
      space util
        bias := 10
        fn add(x) => x + bias
        task double(x) => x * 2
        proto Box(x)
          slot x := x
          fn total() => self.x + bias
        end
      end
      = util.add(5)
      = util.double(7).await()
      b := util.Box(3)
      = b.total()
      = util.keys()
    RSH
    assert_equal "15\n14\n13\n[\"Box\", \"add\", \"bias\", \"double\"]\n", @out.string
  end

  def test_safe_argv_command_values_preserve_arguments
    skip 'printf unavailable' unless @app.executor.find_executable('printf')
    run_script <<~'RSH'
      c := cmd("printf", "%s", "hello world")
      = c.capture()
      = c.argv()
    RSH
    assert_equal "hello world\n[\"printf\", \"%s\", \"hello world\"]\n", @out.string
  end

  def test_attempt_returns_structured_error_value
    value = @eval.parse_eval('attempt(:: => fail("boom"))')
    assert_equal false, value['ok']
    assert_match(/boom/, value.dig('error', 'message'))
  end

  def test_task_timeout_is_reported
    error = assert_raises(Srsh::RuntimeError) do
      @eval.parse_eval('(&:: => (sleep(0.05) ?? 1)).await(0.001)')
    end
    assert_match(/timed out/, error.message)
  end
end

class SrshPowerHardeningTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-power-hardening')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_cancel_is_a_terminal_task_state
    task = Srsh::Language::TaskValue.new do
      sleep 0.05
      42
    end
    assert task.cancel
    sleep 0.01
    assert_equal 'cancelled', task.status
    assert_raises(Srsh::RuntimeError) { task.await(0.1) }
    assert_equal 'cancelled', task.status
  end

  def test_structured_command_output_limit_reaps_child
    error = assert_raises(Srsh::RuntimeError) do
      @eval.send(:run_argv, [RbConfig.ruby, '-e', 'STDOUT.write("x" * (5 * 1024 * 1024))'])
    end
    assert_match(/output exceeds/, error.message)
  end

  def test_atom_stress_from_many_tasks
    value = @eval.parse_eval(<<~'RSH'.strip)
      atom(0)
    RSH
    tasks = 200.times.map do
      Srsh::Language::TaskValue.new { value.swap { |n| n + 1 } }
    end
    tasks.each { |task| task.await(2) }
    assert_equal 200, value.get
  end
end

class SrshPipelinePrecedenceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-pipe-precedence')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_pipeline_finishes_before_comparison_boolean_and_fallback
    assert_equal true, @eval.parse_eval('[1,2,3] |> len == 3')
    assert_equal true, @eval.parse_eval('[1,2,3] |> len > 2 and yes')
    assert_equal 3, @eval.parse_eval('[1,2,3] |> len ?? 99')
  end

  def test_range_and_arithmetic_feed_pipeline_as_whole_value
    assert_equal 4, @eval.parse_eval('1 .. 4 |> len')
    assert_equal 3, @eval.parse_eval('1 + 2 |> int')
  end
end

class SrshDeclarationValidationTest < Minitest::Test
  def parse(source)
    Srsh::Language::ProgramParser.new(source).parse
  end

  def test_duplicate_parameters_are_rejected
    assert_raises(Srsh::ParseError) { parse("fn bad(x, x) => x\n") }
  end

  def test_duplicate_proto_members_are_rejected
    assert_raises(Srsh::ParseError) do
      parse(<<~RSH)
        proto Bad()
          slot value := 1
          slot value := 2
        end
      RSH
    end
  end

  def test_duplicate_trait_methods_are_rejected
    assert_raises(Srsh::ParseError) do
      parse(<<~RSH)
        trait Bad
          fn x() => 1
          fn x() => 2
        end
      RSH
    end
  end
end

class SrshStructuredConcurrencyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-structured-concurrency')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_race_cancels_losers
    fast = Srsh::Language::TaskValue.new { sleep 0.002; 'fast' }
    slow = Srsh::Language::TaskValue.new { sleep 1; 'slow' }
    assert_equal 'fast', @eval.send(:builtin_function, 'race', [[fast, slow]])
    sleep 0.005
    assert_equal 'cancelled', slow.status
  end

  def test_await_all_cancels_siblings_after_failure
    bad = Srsh::Language::TaskValue.new { sleep 0.002; raise Srsh::RuntimeError, 'boom' }
    slow = Srsh::Language::TaskValue.new { sleep 1; 1 }
    error = assert_raises(Srsh::RuntimeError) do
      @eval.send(:builtin_function, 'await_all', [[bad, slow]])
    end
    assert_match(/boom/, error.message)
    sleep 0.005
    assert_equal 'cancelled', slow.status
  end
end

class SrshTaskIsolationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-task-isolation')
    @out = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_script(source)
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
  end

  def test_task_argument_plain_map_is_copied
    run_script <<~RSH
      cfg := %[count: 1]
      task bump(x)
        x.count := 9
        return x.count
      end
      = bump(cfg).await()
      = cfg.count
    RSH
    assert_equal "9\n1\n", @out.string
  end

  def test_task_capture_plain_map_is_copied
    run_script <<~RSH
      cfg := %[count: 1]
      task bump()
        cfg.count := 7
        return cfg.count
      end
      = bump().await()
      = cfg.count
    RSH
    assert_equal "7\n1\n", @out.string
  end

  def test_parallel_plain_map_items_do_not_mutate_source_collection
    run_script <<~RSH
      rows := [%[n: 1], %[n: 2]]
      fn bump(row)
        row.n += 10
        return row.n
      end
      = parallel(rows, bump, 2)
      = rows
    RSH
    assert_equal "[11, 12]\n[%[n: 1], %[n: 2]]\n", @out.string
  end

  def test_worker_cannot_mutate_shared_namespace_directly
    run_script <<~RSH
      space cfg
        value := 1
      end
      task mutate()
        cfg.value := 9
      end
      t := mutate()
      r := attempt(:: => t.await())
      = r.ok
      = cfg.value
    RSH
    assert_equal "no\n1\n", @out.string
  end
end

class SrshCheckedCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-command-check')
    @app = Srsh::App.new(home: @dir, out: StringIO.new, err: StringIO.new)
    @eval = @app.executor.evaluator
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_check_returns_result_on_zero_status
    command = Srsh::Language::CommandValue.new([RbConfig.ruby, '-e', 'STDOUT.write("ok")'])
    result = @eval.send(:native_method, command, 'check', [])
    assert_equal 0, result['status']
    assert_equal 'ok', result['out']
  end

  def test_check_raises_with_status_and_stderr
    command = Srsh::Language::CommandValue.new([RbConfig.ruby, '-e', 'STDERR.write("bad"); exit 7'])
    error = assert_raises(Srsh::RuntimeError) { @eval.send(:native_method, command, 'check', []) }
    assert_match(/status 7/, error.message)
    assert_match(/bad/, error.message)
    assert_equal 7, @app.state.last_status
  end
end

class SrshOnePointZeroLanguageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-1.0-lang')
    @out = StringIO.new
    @err = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: @err)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_multiline_collection_assignment_is_one_statement
    source = <<~RSH
      jobs := [
        1,
        2,
        3
      ]
      = jobs |> sum
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "6\n", @out.string
  end

  def test_arrow_body_can_start_on_next_line_inside_space
    source = <<~RSH
      space math
        task twice(x) =>
          int(x) * 2
      end
      = math.twice(7).await()
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "14\n", @out.string
  end

  def test_bare_value_pipeline_is_expression_statement_not_shell_command
    source = <<~RSH
      seen := atom(0)
      [1,2,3] |> each(::x => seen.swap(::n => n + x))
      = seen.get()
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "6\n", @out.string
  end

  def test_bridge_calls_c_symbol_and_cbuf_can_hold_output
    source = <<~RSH
      bridge c from "@self"
        strlen(cstr) -> usize
      end
      = c.strlen("hello")
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "5\n", @out.string
  rescue Srsh::RuntimeError => e
    skip "runtime does not export strlen: #{e.message}"
  end

  def test_use_loads_module_into_namespace
    module_path = File.join(@dir, 'mathish.rsh')
    File.write(module_path, "bias := 5\nfn add(x) => int(x) + bias\n")
    source = "use #{module_path.inspect} as mathish\n= mathish.add(7)\n"
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "12\n", @out.string
  end

  def test_defer_runs_lifo_on_function_return
    path = File.join(@dir, 'cleanup.txt')
    source = <<~RSH
      fn work()
        writefile(#{path.inspect}, "live")
        defer writefile(#{path.inspect}, "first")
        defer writefile(#{path.inspect}, "last")
        return 9
      end
      = work()
      = readfile(#{path.inspect})
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "9\nfirst\n", @out.string
  end

  def test_proto_slot_accepts_multiline_value
    source = <<~RSH
      proto Bag()
        slot values := [
          1,
          2,
          3
        ]
      end
      bag := Bag()
      = bag.values |> sum
    RSH
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "6\n", @out.string
  end

  def test_incomplete_expression_uses_incomplete_input_error
    assert_raises(Srsh::IncompleteInput) do
      Srsh::Language::ProgramParser.new("jobs := [\n").parse
    end
  end
end

class SrshRelativeModuleTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('srsh-module-relative')
    @out = StringIO.new
    @app = Srsh::App.new(home: @dir, out: @out, err: StringIO.new)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_module_function_can_use_file_relative_to_module
    lib = File.join(@dir, 'lib')
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, 'inner.rsh'), "fn value() => 41\n")
    File.write(File.join(lib, 'outer.rsh'), <<~RSH)
      fn answer()
        use "./inner.rsh" as inner
        return inner.value() + 1
      end
    RSH
    source = "use #{File.join(lib, 'outer.rsh').inspect} as outer\n= outer.answer()\n"
    @app.executor.run_program(Srsh::Language::ProgramParser.new(source).parse)
    assert_equal "42\n", @out.string
  end
end
