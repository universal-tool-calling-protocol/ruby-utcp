# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/local_tcp_server"

class HTTPLimitsTest < Minitest::Test
  include LocalTCPServer

  def test_http_size_limit_aborts_before_the_server_finishes_the_body
    closed = Queue.new
    handler = lambda do |socket|
      read_http_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n" + "x" * 64)
      closed << socket.read
    end
    with_tcp_server(handler) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/", max_response_bytes: 32, timeout: 1)
      error = assert_raises(UTCP::ToolCallError) { UTCP::HTTPProtocol.new.call_tool(nil, "large", {}, template) }
      assert_match(/max_response_bytes/, error.message)
      assert_equal "", Timeout.timeout(1) { closed.pop }
    end
  end

  def test_http_total_timeout_bounds_a_response_that_keeps_sending_bytes
    handler = lambda do |socket|
      read_http_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n")
      100.times { socket.write("x"); sleep 0.01 }
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end
    with_tcp_server(handler) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/", timeout: 1, total_timeout: 0.08)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(UTCP::TimeoutError) { UTCP::HTTPProtocol.new.call_tool(nil, "slow", {}, template) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.7
    end
  end

  def test_stream_total_timeout_and_early_break_release_the_socket
    [false, true].each do |stop_early|
      handler = lambda do |socket|
        read_http_request(socket)
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        100.times { socket.write("data: 1\n\n"); sleep 0.01 }
      rescue Errno::EPIPE, Errno::ECONNRESET
        nil
      end
      with_tcp_server(handler) do |port|
        template = UTCP::SseCallTemplate.new(url: "http://127.0.0.1:#{port}/", timeout: 1, total_timeout: 0.08)
        stream = UTCP::SSEProtocol.new.call_tool_streaming(nil, "events", {}, template)
        if stop_early
          assert_equal [1], stream.take(1)
        else
          assert_raises(UTCP::TimeoutError) { stream.to_a }
        end
      end
    end
  end

  def test_http_limits_are_preserved_across_redirects
    protocol = FakeHTTPProtocol.new do |request|
      if request[:target] == "/"
        FakeHTTPResponse.new(code: 302, headers: { "Location" => "/large" })
      else
        FakeHTTPResponse.new(body: "x" * 20)
      end
    end
    template = UTCP::HttpCallTemplate.new(url: "https://example.test/", max_response_bytes: 10)
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, template) }
    assert_equal 2, protocol.requests.length
  end
end
