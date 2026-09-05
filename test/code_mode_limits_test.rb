# frozen_string_literal: true

require_relative "test_helper"

class CodeModeLimitsTest < Minitest::Test
  def setup
    @client = UTCP::CodeModeClient.create
  end

  def result(source, **options)
    @client.call_tool_chain(source, **options).fetch("result")
  end

  def test_accepts_thirty_mebibytes_and_rejects_one_more_byte
    bytes = 30 * 1024 * 1024
    assert_equal bytes, result("'x' * #{bytes}").bytesize
    assert_raises(UTCP::CodeModeLimitError) { result("'x' * #{bytes + 1}") }
  end

  def test_rejects_an_oversized_hash_key_returned_by_a_tool
    payload = { "k" * (UTCP::CodeMode::MAX_VALUE_BYTES + 1) => nil }
    @client.define_singleton_method(:call_tool) { |*_args| payload }
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool("test"); 0') }
  end

  def test_string_and_symbol_keys_share_the_byte_budget_with_values
    ["ż", :label].each do |key|
      payload = { key => "x" * (UTCP::CodeMode::MAX_VALUE_BYTES - key.to_s.bytesize) }
      @client.define_singleton_method(:call_tool) { |*_args| payload }
      value = result('codemode.call_tool("test")')
      assert_equal [key], value.keys
      assert_equal UTCP::CodeMode::MAX_VALUE_BYTES - key.to_s.bytesize, value[key].bytesize

      payload = { key => payload[key] + "x" }
      assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool("test"); 0') }
    end
  end

  def test_checks_hash_keys_in_workflow_results_and_tool_arguments
    source = "{('k' * #{UTCP::CodeMode::MAX_VALUE_BYTES}) => 'v'}"
    called = false
    @client.define_singleton_method(:call_tool) { |*_args| called = true }
    assert_raises(UTCP::CodeModeLimitError) { result(source) }
    assert_raises(UTCP::CodeModeLimitError) { result("codemode.call_tool('test', #{source})") }
    refute called
  end

  def test_stream_stops_at_the_first_item_over_the_shared_byte_budget
    %w[call_tool_stream call_tool_streaming].each do |method|
      yielded = 0
      closed = false
      chunk = "x" * (UTCP::CodeMode::MAX_VALUE_BYTES / 2)
      stream = Enumerator.new do |output|
        5.times do
          yielded += 1
          output << chunk
        end
      ensure
        closed = true
      end
      @client.define_singleton_method(:call_tool_streaming) { |*_args| stream }

      assert_raises(UTCP::CodeModeLimitError) { result("codemode.#{method}('test'); 0") }
      assert_equal 3, yielded
      assert closed, "the producer must unwind when the stream exceeds its budget"
    end
  end

  def test_stream_accepts_the_exact_byte_budget
    chunk = "x" * (UTCP::CodeMode::MAX_VALUE_BYTES / 2)
    @client.define_singleton_method(:call_tool_streaming) { |*_args| [chunk, chunk].each }
    assert_equal [chunk.bytesize, chunk.bytesize], result('codemode.call_tool_stream("test").map { |item| item.length }')
  end

  def test_stream_item_budget_includes_the_root_array_and_stops_early
    count = UTCP::CodeMode::MAX_VALUE_ITEMS - 1
    yielded = 0
    @client.define_singleton_method(:call_tool_streaming) do |*_args|
      Enumerator.new do |output|
        count.times { yielded += 1; output << nil }
      end
    end
    assert_equal count, result('codemode.call_tool_stream("test").length')

    count += 3
    yielded = 0
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool_stream("test"); 0') }
    assert_equal UTCP::CodeMode::MAX_VALUE_ITEMS, yielded
  end

  def test_stream_items_consume_execution_steps
    yielded = 0
    @client.define_singleton_method(:call_tool_streaming) do |*_args|
      Enumerator.new { |output| 100.times { yielded += 1; output << nil } }
    end
    assert_raises(UTCP::CodeModeLimitError) { result('codemode.call_tool_stream("test")', max_steps: 20) }
    assert_operator yielded, :<, 100
  end
end
