# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "json"
require_relative "../examples/coding_agent/llm"

class CodingAgentLLMTest < Minitest::Test
  def serve(body, status: 200)
    server = TCPServer.new("127.0.0.1", 0)
    captured = Queue.new
    thread = Thread.new do
      socket = server.accept
      headers = +""
      headers << socket.read(1) until headers.end_with?("\r\n\r\n")
      length = headers[/Content-Length: (\d+)/i, 1].to_i
      captured << [headers, JSON.parse(socket.read(length))]
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/v1", captured
  ensure
    server.close if server
    thread.join(2) if thread
    thread.kill if thread && thread.alive?
  end

  def test_request_and_response_use_chat_completions_shape
    body = JSON.generate("choices" => [{ "finish_reason" => "stop", "message" => { "role" => "assistant", "content" => "hello" } }])
    serve(body) do |url, captured|
      llm = RubyUTCPAgent::LLM.new(api_key: "test-key", model: "test-model", base_url: url)
      assert_equal "hello", llm.complete(messages: [{ "role" => "user", "content" => "hi" }], tools: [])["content"]
      headers, request = captured.pop
      assert_includes headers, "POST /v1/chat/completions"
      assert_includes headers, "Bearer test-key"
      assert_equal "test-model", request["model"]
      assert_equal false, request["stream"]
    end
  end

  def test_errors_and_truncated_completions_do_not_become_successful_answers
    [ ['{}', 401], ['not json', 200],
      [JSON.generate("choices" => [{ "finish_reason" => "length", "message" => { "content" => "partial" } }]), 200] ].each do |body, status|
      serve(body, status: status) do |url, _|
        llm = RubyUTCPAgent::LLM.new(api_key: "key", model: "model", base_url: url)
        assert_raises(RubyUTCPAgent::LLM::Error) { llm.complete(messages: [], tools: []) }
      end
    end
  end

  def test_insecure_remote_urls_and_missing_configuration_are_rejected
    assert_raises(ArgumentError) { RubyUTCPAgent::LLM.new(api_key: "key", model: "model", base_url: "http://example.com/v1") }
    assert_raises(ArgumentError) { RubyUTCPAgent::LLM.new(api_key: "", model: "model") }
    assert_raises(ArgumentError) { RubyUTCPAgent::LLM.new(api_key: "key", model: " ") }
  end
end
