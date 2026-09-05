# frozen_string_literal: true

require_relative "test_helper"

class CodeModeTest < Minitest::Test
  class CodeModeTemplate < UTCP::CallTemplate
    attr_reader :manual_data

    def initialize(manual_data:, call_template_type: "code_mode_test", **options)
      super(call_template_type: call_template_type, **options)
      @manual_data = manual_data
    end

    def to_h
      super.merge("manual_data" => manual_data)
    end
  end

  class CodeModeProtocol < UTCP::CommunicationProtocol
    def register_manual(_client, template)
      UTCP::RegisterManualResult.new(
        manual_call_template: template,
        manual: UTCP::Manual.from_h(template.manual_data),
        success: true
      )
    end

    def call_tool(_client, name, arguments, _template)
      values = UTCP::Utils.stringify_keys(arguments)
      case name
      when "calc.add" then values.fetch("a") + values.fetch("b")
      when "calc.multiply" then values.fetch("value") * values.fetch("factor")
      when "calc.fail" then raise "intentional failure"
      else arguments
      end
    end
  end

  def setup
    UTCP.register_call_template("code_mode_test", CodeModeTemplate)
    UTCP.register_protocol("code_mode_test", CodeModeProtocol.new)
    @client = UTCP::CodeModeUtcpClient.create(config: {
      manual_call_templates: [{
        name: "calc",
        call_template_type: "code_mode_test",
        manual_data: {
          utcp_version: "1.1.0",
          tools: [
            tool("add", "Add two numbers", a: "number", b: "number"),
            tool("multiply", "Multiply two numbers", value: "number", factor: "number"),
            tool("fail", "Always fails")
          ]
        }
      }]
    })
  end

  def tool(name, description, properties = {})
    {
      name: name,
      description: description,
      inputs: {
        type: "object",
        properties: properties.transform_values { |type| { type: type } },
        required: properties.keys.map(&:to_s)
      },
      outputs: { type: "number" },
      tool_call_template: { call_template_type: "code_mode_test", manual_data: {} }
    }
  end

  def test_chains_namespaced_tools_and_processes_results
    execution = @client.call_tool_chain(<<~RUBY)
      sum = codemode.call_tool("calc.add", a: 2, b: 3)
      product = codemode.call_tool("calc.multiply", value: sum, factor: 4)
      selected = [sum, product, 2].select { |value| value >= 5 }.map { |value| value * 2 }
      puts "completed", selected.length
      return({ sum: sum, product: product, selected: selected })
    RUBY

    assert_equal({ "sum" => 5, "product" => 20, "selected" => [10, 40] }, execution["result"])
    assert_equal ["completed 2"], execution["logs"]
  end

  def test_codemode_call_tool_and_final_expression
    execution = @client.call_tool_chain(<<~RUBY)
      sum = codemode.call_tool("calc.add", a: 7, b: 8)
      codemode.call_tool("calc.multiply", value: sum, factor: 2)
    RUBY

    assert_equal 30, execution["result"]
  end

  def test_supports_conditionals
    execution = @client.call_tool_chain(<<~RUBY)
      value = codemode.call_tool("calc.add", a: 1, b: 2)
      if value > 10
        "large"
      elsif value == 3
        "three"
      else
        "small"
      end
    RUBY
    assert_equal "three", execution["result"]

    execution = @client.call_tool_chain("unless false\n  'ran'\nelse\n  'skipped'\nend")
    assert_equal "ran", execution["result"]
  end

  def test_supports_hash_iteration_and_streaming_helper
    execution = @client.call_tool_chain(<<~RUBY)
      pairs = { a: 1, b: 2 }.map { |key, value| key.to_s + value.to_s }
      chunks = codemode.call_tool_stream("calc.add", a: 2, b: 4)
      { pairs: pairs, chunk: chunks.first }
    RUBY

    assert_equal ["a1", "b2"], execution["result"]["pairs"]
    assert_equal 6, execution["result"]["chunk"]
  end

  def test_exposes_search_and_interface_introspection
    execution = @client.call_tool_chain(<<~RUBY)
      matches = codemode.search_tools("add", limit: 1)
      descriptor = codemode.get_tool_interface("calc.add")
      { match: matches.first["name"], required: descriptor["inputs"]["required"],
        interface_found: codemode.interfaces.include?("calc.add") }
    RUBY

    assert_equal "calc.add", execution["result"]["match"]
    assert_equal %w[a b], execution["result"]["required"]
    assert execution["result"]["interface_found"]
    assert_includes @client.get_all_tools_ruby_interfaces, 'codemode.call_tool("calc.add", a:'
  end

  def test_rejects_process_and_reflection_access
    assert_raises(UTCP::CodeModeSyntaxError) { @client.call_tool_chain('system("whoami")') }
    assert_raises(UTCP::CodeModeSyntaxError) { @client.call_tool_chain('"x".send(:upcase)') }
    assert_raises(UTCP::CodeModeSyntaxError) { @client.call_tool_chain("calc.multiply") }
  end

  def test_enforces_timeout_and_step_limit
    assert_raises(UTCP::CodeModeTimeoutError) do
      @client.call_tool_chain("while true\nend", timeout: 0.01, max_steps: 1_000_000)
    end
    assert_raises(UTCP::CodeModeLimitError) do
      @client.call_tool_chain("while true\nend", timeout: 1, max_steps: 10)
    end
  end

  def test_rejects_oversized_integer_powers_even_when_result_is_discarded
    %w[2 -2].each do |base|
      [UTCP::CodeMode::MAX_INTEGER_BITS, -UTCP::CodeMode::MAX_INTEGER_BITS].each do |exponent|
        error = assert_raises(UTCP::CodeModeLimitError) do
          @client.call_tool_chain("(#{base}) ** #{exponent}; 0", max_steps: 100)
        end
        assert_match(/Integer power/, error.message)
      end
    end
  end

  def test_allows_small_and_constant_size_powers
    execution = @client.call_tool_chain("[2 ** 8, 2 ** -3, (-2) ** 3, 0 ** 10000000, 1 ** 10000000, (-1) ** 10000000]")
    assert_equal [256, Rational(1, 8), -8, 0, 1, 1], execution["result"]
  end

  def test_rejects_oversized_integer_products
    error = assert_raises(UTCP::CodeModeLimitError) do
      @client.call_tool_chain("value = 2 ** #{UTCP::CodeMode::MAX_INTEGER_BITS / 2}; value * value; 0")
    end
    assert_match(/Integer product/, error.message)
  end

  def test_large_numbers_returned_by_tools_count_toward_value_budget
    value = 1 << UTCP::CodeMode::MAX_INTEGER_BITS
    @client.define_singleton_method(:call_tool) { |_name, _arguments| value }
    assert_raises(UTCP::CodeModeLimitError) { @client.call_tool_chain('codemode.call_tool("calc.add")') }
  end

  def test_numeric_budget_is_shared_by_values_in_a_collection
    value = 1 << (UTCP::CodeMode::MAX_INTEGER_BITS / 2)
    @client.define_singleton_method(:call_tool) { |_name, _arguments| [value, value] }
    assert_raises(UTCP::CodeModeLimitError) { @client.call_tool_chain('codemode.call_tool("calc.add")') }
  end

  def test_rejects_non_finite_numbers
    assert_raises(UTCP::CodeModeLimitError) { @client.call_tool_chain("1.0e300 * 1.0e300") }
  end

  def test_wraps_tool_failures_with_captured_logs
    error = assert_raises(UTCP::CodeModeExecutionError) do
      @client.call_tool_chain("puts 'starting'\ncodemode.call_tool('calc.fail')")
    end

    assert_equal ["starting"], error.logs
    assert_includes error.message, "intentional failure"
  end

  def test_can_rescue_tool_failures_inside_the_workflow
    execution = @client.call_tool_chain(<<~RUBY)
      begin
        codemode.call_tool("calc.fail")
      rescue => error
        warn error.message
        { recovered: true, type: error.type }
      ensure
        puts "finished"
      end
    RUBY

    assert_equal({ "recovered" => true, "type" => "UTCP::ToolCallError" }, execution["result"])
    assert_equal 2, execution["logs"].length
    assert_match(/intentional failure/, execution["logs"].first)
    assert_equal "finished", execution["logs"].last
  end
end
