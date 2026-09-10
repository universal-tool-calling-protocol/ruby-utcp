# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../examples/coding_agent/agent"

class CodingAgentLoopTest < Minitest::Test
  Tool = Struct.new(:name, :description, :inputs)

  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def list_tools
      [Tool.new("workspace.read_file", "Read", { "type" => "object", "properties" => {} })]
    end

    def call_tool(name, args)
      @calls << [name, args]
      { "content" => "hello" }
    end
  end

  class FakeLLM
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def complete(messages:, tools:)
      @requests << JSON.parse(JSON.generate("messages" => messages, "tools" => tools))
      @responses.shift || { "role" => "assistant", "content" => "done" }
    end
  end

  def tool_call(id, name = "workspace_read_file", args = '{"path":"x.rb"}')
    { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => args } }
  end

  def assistant(*calls)
    { "role" => "assistant", "content" => nil, "tool_calls" => calls,
      "reasoning_details" => [{ "type" => "reasoning.encrypted", "data" => "opaque" }] }
  end

  def build(llm, **options)
    @client = FakeClient.new
    RubyUTCPAgent::Agent.new(client: @client, llm: llm, **options)
  end

  def test_executes_via_utcp_and_preserves_tool_ids_and_provider_reasoning_details
    llm = FakeLLM.new(assistant(tool_call("a"), tool_call("b")), { "role" => "assistant", "content" => "Fixed" })
    result = build(llm).run("Fix x.rb")
    assert_equal "completed", result.status
    assert_equal "Fixed", result.answer
    assert_equal 2, @client.calls.length
    history = llm.requests.last["messages"]
    assert_equal %w[a b], history.select { |m| m["role"] == "tool" }.map { |m| m["tool_call_id"] }
    assert_equal "opaque", history.find { |m| m["tool_calls"] }["reasoning_details"][0]["data"]
  end

  def test_bad_json_unknown_tools_and_non_object_arguments_are_recoverable
    calls = [tool_call("a", "workspace_read_file", "{bad"), tool_call("b", "unknown"),
             tool_call("c", "workspace_read_file", "[]")]
    llm = FakeLLM.new(assistant(*calls))
    assert_equal "completed", build(llm).run("inspect").status
    assert_empty @client.calls
    errors = llm.requests.last["messages"].select { |m| m["role"] == "tool" }
    assert_equal 3, errors.length
    assert errors.all? { |m| JSON.parse(m["content"]).key?("error") }
  end

  def test_iteration_limit_is_not_reported_as_success
    llm = FakeLLM.new(assistant(tool_call("a")), assistant(tool_call("b")))
    result = build(llm, max_turns: 2).run("inspect")
    assert_equal "limit", result.status
    assert_equal 2, result.iterations
    assert_match(/limit/i, result.answer)
  end

  def test_large_batch_is_rejected_without_dropping_correlated_results
    calls = 9.times.map { |i| tool_call(i.to_s) }
    llm = FakeLLM.new(assistant(*calls))
    build(llm).run("inspect")
    assert_empty @client.calls
    assert_equal 9, llm.requests.last["messages"].count { |m| m["role"] == "tool" }
  end

  def test_malformed_or_duplicate_ids_are_rejected_before_any_side_effect
    [assistant(tool_call("a"), tool_call("a")), assistant(tool_call(nil))].each do |message|
      agent = build(FakeLLM.new(message))
      assert_raises(RubyUTCPAgent::Agent::Error) { agent.run("inspect") }
      assert_empty @client.calls
      refute agent.messages.any? { |m| m["tool_calls"] }
    end
  end

  def test_reset_clears_previous_task_without_removing_system_prompt
    agent = build(FakeLLM.new)
    agent.run("inspect")
    agent.reset
    assert_equal ["system"], agent.messages.map { |message| message["role"] }
  end

  def test_codemode_is_optional_and_uses_the_execution_api
    executor = Object.new
    def executor.execute(code, timeout:, max_steps:)
      { "result" => code, "logs" => [timeout, max_steps] }
    end
    llm = FakeLLM.new(assistant(tool_call("a", "codemode_run_code", '{"code":"1 + 1"}')))
    build(llm, code_mode: executor).run("compute")
    assert_equal "1 + 1", JSON.parse(llm.requests.last["messages"].last["content"])["result"]
    assert llm.requests.first["tools"].any? { |t| t["function"]["name"] == "codemode_run_code" }
  end

  def test_unserializable_result_still_gets_a_correlated_error_message
    llm = FakeLLM.new(assistant(tool_call("bad-result")))
    agent = build(llm)
    @client.define_singleton_method(:call_tool) { |*_args| Float::INFINITY }
    assert_equal "completed", agent.run("inspect").status
    message = llm.requests.last["messages"].last
    assert_equal "bad-result", message["tool_call_id"]
    assert JSON.parse(message["content"]).key?("error")
  end

end
