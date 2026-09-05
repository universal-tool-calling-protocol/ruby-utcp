# frozen_string_literal: true

require_relative "test_helper"

class CodeModeBehaviorTest < Minitest::Test
  def setup
    @client = UTCP::CodeModeClient.create
  end

  def result(source, **options)
    @client.call_tool_chain(source, **options).fetch("result")
  end

  def assert_result(expected, source)
    actual = result(source)
    expected.nil? ? assert_nil(actual, source) : assert_equal(expected, actual, source)
  end

  def test_literals_arithmetic_comparisons_and_short_circuiting
    {
      '[]' => [], '{}' => {}, 'nil' => nil, 'true' => true, 'false' => false,
      '"value: #{2 + 3}"' => "value: 5", ':hello.to_s' => "hello",
      '[+2, -3, !nil, !0, 9 - 2, 9 / 2, 9 % 2]' => [2, -3, true, false, 7, 4, 1],
      '[1 == 1, 1 != 1, 1 < 2, 1 <= 1, 2 > 1, 2 >= 2, 2 <=> 3]' => [true, false, true, true, true, true, -1],
      '[false && (1 / 0), true || (1 / 0), nil || 4, true && 5]' => [false, true, 4, 5],
      'value = (false or 7); value' => 7,
      'value = (true and 8); value' => 8
    }.each { |source, expected| assert_result(expected, source) }
  end

  def test_assignments_indexing_and_scope_updates
    assert_result([4, { "a" => 5 }], 'a = [1, {"a" => 2}]; a[0] += 3; a[1]["a"] = 5; a')
    assert_result(["bc", [2, 3], 4], '["abcd"[1, 2], [1, 2, 3][1, 2], {"x" => 4}["x"]]')
    assert_result(6, 'sum = 0; [1, 2, 3].each { |value| sum += value }; sum')
    assert_result([["a", 1], ["b", 2]], '{"a" => 1, "b" => 2}.map { |pair| pair }')
    assert_result([2, 3], "[1, 2].map do |value|\n value + 1\nend")
  end

  def test_conditionals_loops_next_break_and_return
    {
      'if true; 1; else; 2; end' => 1,
      'if false; 1; else; 2; end' => 2,
      'if false; 1; end' => nil,
      'unless true; 1; else; 2; end' => 2,
      'unless true; 1; end' => nil,
      '[(1 if true), (2 if false), (3 unless false), (4 unless true)]' => [1, nil, 3, nil],
      'i = 0; until i == 3; i += 1; end; i' => 3,
      'i = 0; sum = 0; while i < 5; i += 1; next if i == 2; break 99 if i == 4; sum += i; end; sum' => 4,
      '[1, 2, 3].map { |x| next 8 if x == 2; x }' => [1, 8, 3],
      '[1, 2, 3].each { |x| break x if x == 2 }' => 2,
      'return; 42' => nil,
      'return 1, 2; 42' => [1, 2]
    }.each { |source, expected| assert_result(expected, source) }
  end

  def test_collection_methods_cover_empty_and_nonempty_results
    {
      '[1, 2, 3].collect { |x| x * 2 }' => [2, 4, 6],
      '[1, 2, 3].filter { |x| x > 1 }' => [2, 3],
      '[1, 2, 3].reject { |x| x > 1 }' => [1],
      '[1, 2, 3].find { |x| x > 1 }' => 2,
      '[1, 2, 3].find { |x| x > 5 }' => nil,
      '[1, 2].any? { |x| x == 2 }' => true,
      '[1, 2].any? { |x| x > 2 }' => false,
      '[1, 2].all? { |x| x > 0 }' => true,
      '[1, 2].all? { |x| x > 1 }' => false,
      '[1, 2].none? { |x| x > 2 }' => true,
      '[1, 2].none? { |x| x == 2 }' => false,
      '[[1, 2, 2].count(2), [1, 2].count { |x| x > 1 }]' => [2, 1],
      '[3, 1, 2].sort_by { |x| -x }' => [3, 2, 1],
      '[1, 2, 3].reduce { |sum, x| sum + x }' => 6,
      '[1, 2, 3].inject(10) { |sum, x| sum + x }' => 16,
      '[].reduce { |sum, x| sum + x }' => nil,
      '(1..3).map { |x| x * 2 }' => [2, 4, 6]
    }.each { |source, expected| assert_result(expected, source) }
  end

  def test_safe_value_methods
    {
      '[nil.nil?, [].empty?, [1].size, "12".to_i, "1.5".to_f, 3.inspect]' => [true, true, 1, 12, 1.5, "3"],
      '[[1, 2].first, [1, 2].last, [1, 2].first(1), [1, 2].last(1)]' => [1, 2, [1], [2]],
      '[[1, 2, 3].take(2), [1, 2, 3].drop(2)]' => [[1, 2], [3]],
      '[[2, 1].reverse, [2, 1].sort, [1, 1].uniq, [nil, 1].compact, [[1], [2]].flatten]' => [[1, 2], [1, 2], [1], [1], [1, 2]],
      '[[1, 2].min, [1, 2].max, [1, 2].sum, (1..3).sum]' => [1, 2, 3, 6],
      '[{"a" => 1}.keys, {"a" => 1}.values, {"a" => 1}.to_h, {"a" => 1}.to_a]' => [["a"], [1], { "a" => 1 }, [["a", 1]]],
      '[[1, 2].to_a, (1...3).to_a, (1..3).to_a, ("a".."c").to_a]' => [[1, 2], [1, 2], [1, 2, 3], %w[a b c]],
      '[" a ".strip, "Ab".downcase, "ab".upcase, "a,b".split(","), ["a", "b"].join("-")]' => ["a", "ab", "AB", %w[a b], "a-b"],
      '["abc".start_with?("a"), "abc".end_with?("c"), [1, 2].include?(2), {"x" => 1}.key?("x"), {"x" => 1}.has_key?("z")]' => [true, true, true, true, false],
      '[{"x" => 1}.fetch("x"), {"a" => {"b" => 2}}.dig("a", "b"), [1, 2].slice(0, 1), {"a" => 1}.merge({"b" => 2})]' => [1, 2, [1], { "a" => 1, "b" => 2 }],
      '[(-2).abs, 1.2.ceil, 1.8.floor, 1.6.round, 0.zero?, 1.positive?, (-1).negative?, 2.even?, 3.odd?]' => [2, 2, 1, 2, true, true, true, true, true]
    }.each { |source, expected| assert_result(expected, source) }
  end

  def test_runtime_get_defaults_and_arity
    assert_result([1, 9, 2, 9, "b", 9], '[codemode.get({"a" => 1}, "a"), codemode.get({}, "x", 9), codemode.get([1, 2], 1), codemode.get([], 2, 9), codemode.get("abc", 1), codemode.get("abc", 9, 9)]')
    assert_raises(UTCP::CodeModeExecutionError) { result('codemode.get(1, "x")') }
    assert_raises(UTCP::CodeModeSyntaxError) { result('codemode.get({})') }
    assert_raises(UTCP::CodeModeSyntaxError) { result('codemode.interfaces { 1 }') }
    assert_raises(UTCP::CodeModeSyntaxError) { result('codemode.unknown') }
  end

  def test_rescue_else_ensure_and_unrescuable_limits
    assert_result(7, '(1 / 0) rescue 7')
    assert_result(2, 'begin; 1; rescue; 0; else; 2; ensure; puts "done"; end')
    assert_result(3, 'begin; 1 / 0; rescue; 3; end')
    assert_result(5, 'begin; return 5; ensure; puts "done"; end')
    assert_raises(UTCP::CodeModeSyntaxError) { result('begin; 1 / 0; rescue StandardError; 1; end') }
    assert_raises(UTCP::CodeModeSyntaxError) { result('system("x") rescue 1') }
    assert_raises(UTCP::CodeModeLimitError) { result('begin; while true; end; rescue; 1; end', max_steps: 20) }
    error = assert_raises(UTCP::CodeModeExecutionError) { result('puts "before"; 1 / 0') }
    assert_equal ["before"], error.logs
  end

  def test_logs_and_empty_program
    execution = @client.call_tool_chain('puts "a", 1; print "b", 2; p [3]; warn "c"')
    assert_equal ["a 1", "b2", "[3]", "[WARN] c"], execution["logs"]
    assert_nil execution["result"]
    assert_nil result("")
  end

  def test_invalid_syntax_receivers_and_arguments_are_rejected
    ['(', 'class X; end', 'self', '1 << 2', '~1', '[1].map', '[1].map { |x = 1| x }', 'call_tool("x")', '[1][0, 1, 2]', '"x"[0] = "y"', 'a = []; a[0, 1] = 2'].each do |source|
      assert_raises(UTCP::CodeModeSyntaxError, source) { result(source) }
    end
    ['1 + "x"', '1[0]', '[1]["x"]', '1.length', '1.empty?', '1.to_a', '[].to_h', '1.first', '1.join', '1.strip', '1.include?(1)', '1.key?("x")', '1.fetch(0)', '1.keys', '"a".abs', '{}.fetch("missing")'].each do |source|
      assert_raises(UTCP::CodeModeExecutionError, source) { result(source) }
    end
    assert_raises(UTCP::CodeModeSyntaxError) { result('[1].length(2)') }
  end

  def test_size_limits_and_invalid_execution_options
    [0, -1].each do |value|
      assert_raises(UTCP::CodeModeLimitError) { result('1', timeout: value) }
      assert_raises(UTCP::CodeModeLimitError) { result('1', max_steps: value) }
    end
    assert_raises(UTCP::CodeModeLimitError) { result(' ' * (UTCP::CodeMode::MAX_CODE_BYTES + 1)) }
    oversized = UTCP::CodeMode::MAX_VALUE_BYTES + 1
    half = UTCP::CodeMode::MAX_VALUE_BYTES / 2 + 1
    ["\"x\" * #{oversized}", '[1] * 10001', '(1..10001).to_a', "a = \"x\" * #{half}; a + a", 'a = [1] * 6000; a + a', "[\"x\" * #{half}, \"y\" * #{half}].join", 'puts "x" * 600000; puts "y" * 600000'].each do |source|
      assert_raises(UTCP::CodeModeLimitError, source) { result(source) }
    end
  end

  def test_tool_results_and_arguments_are_checked_at_the_boundary
    payload = nil
    received = nil
    @client.define_singleton_method(:call_tool) { |_name, args| received = args; payload }
    assert_nil result('codemode.call_tool("x")')
    assert_equal({}, received)
    payload = { "ok" => [true, false, nil, 1.5] }
    assert_result(payload, 'codemode.call_tool("x", {"a" => 1})')
    assert_equal({ "a" => 1 }, received)
    payload = Object.new
    assert_raises(UTCP::CodeModeExecutionError) { result('codemode.call_tool("x")') }
    payload = "x" * (UTCP::CodeMode::MAX_VALUE_BYTES + 1)
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool("x")') }
    payload = [nil] * (UTCP::CodeMode::MAX_VALUE_ITEMS + 1)
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool("x")') }
    payload = 65.times.reduce(nil) { |value, _| [value] }
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool("x")') }
    assert_raises(UTCP::CodeModeSyntaxError) { result('codemode.call_tool("x", 1)') }
  end

  def test_interfaces_handle_empty_tools_optional_inputs_and_union_types
    assert_equal "# No UTCP tools are registered.", @client.get_all_tools_ruby_interfaces
    assert_raises(UTCP::ToolNotFoundError) { @client.get_tool_interface("missing") }
    assert_raises(UTCP::CodeModeExecutionError) { result('codemode.get_tool_interface("missing")') }
    generator = UTCP::CodeMode::InterfaceGenerator
    { "" => "_", "1name" => "_1name", "class" => "_class", "a-b" => "a_b" }.each do |name, expected|
      assert_equal expected, generator.identifier(name)
    end
    { "string" => "String", "integer" => "Integer", "number" => "Numeric", "boolean" => "Boolean", "array" => "Array", "object" => "Hash", "null" => "Object" }.each do |type, expected|
      assert_equal expected, generator.ruby_type(type: type)
    end
    assert_equal "String | Object", generator.ruby_type(type: %w[string null])
    assert_equal "Object", generator.ruby_type(nil)
    tool = UTCP::Tool.new(name: "a.tool", inputs: { properties: { "class" => { type: "string" } } },
                          tool_call_template: UTCP::TextCallTemplate.new(content: "example"))
    assert_includes generator.new([tool]).render, '_class: nil'
    assert_includes generator.new([tool]).render, '(String, optional)'
  end

  def test_parallel_executions_do_not_share_variables_or_logs
    threads = 8.times.map do |index|
      Thread.new { @client.call_tool_chain("value = #{index}; puts value; value * 2") }
    end
    threads.each_with_index do |thread, index|
      assert thread.join(3), "Code Mode worker did not finish"
      assert_equal({ "result" => index * 2, "logs" => [index.to_s] }, thread.value)
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
