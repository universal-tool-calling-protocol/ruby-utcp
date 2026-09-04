# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/local_tcp_server"

class NetworkFailureTest < Minitest::Test
  include LocalTCPServer

  def test_http_read_timeout_and_connection_loss_are_reported
    with_tcp_server(->(socket) { read_http_request(socket); socket.read }) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/", http_method: "POST", timeout: 0.1)
      assert_raises(UTCP::TimeoutError) { UTCP::HTTPProtocol.new.call_tool(nil, "api.slow", {}, template) }
    end
    with_tcp_server(->(socket) { read_http_request(socket) }) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/", http_method: "POST", timeout: 0.1)
      error = assert_raises(UTCP::ToolCallError) { UTCP::HTTPProtocol.new.call_tool(nil, "api.broken", {}, template) }
      assert_match(/failed/, error.message)
    end
  end

  def test_http_preserves_error_response_and_does_not_follow_unsafe_redirects
    with_tcp_server(->(socket) { read_http_request(socket); socket.write("HTTP/1.1 503 Unavailable\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndown") }) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/")
      error = assert_raises(UTCP::ToolCallError) { UTCP::HTTPProtocol.new.call_tool(nil, "api.down", {}, template) }
      assert_equal 503, error.status
      assert_equal "down", error.response_body
    end
    with_tcp_server(->(socket) { read_http_request(socket); socket.write("HTTP/1.1 302 Found\r\nLocation: http://example.invalid/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }) do |port|
      template = UTCP::HttpCallTemplate.new(url: "http://127.0.0.1:#{port}/")
      assert_raises(UTCP::SecurityError) { UTCP::HTTPProtocol.new.call_tool(nil, "api.redirect", {}, template) }
    end
  end

  def test_tcp_partial_frame_eof_timeout_and_oversize
    [
      ["\x00\x00".b, UTCP::ToolCallError, /complete response/, false],
      [[10].pack("N") + "abc", UTCP::ToolCallError, /complete response/, false],
      [[1000].pack("N"), UTCP::ToolCallError, /max_response_size/, false],
      [[10].pack("N") + "abc", UTCP::TimeoutError, /timed out/, true]
    ].each do |payload, error_class, message, stall|
      with_tcp_server(->(socket) { socket.readpartial(4096); socket.write(payload); socket.read if stall }) do |port|
        template = UTCP::TcpCallTemplate.new(host: "127.0.0.1", port: port, framing_strategy: "length_prefix", timeout: 100, max_response_size: 64)
        error = assert_raises(error_class) { UTCP::TCPProtocol.new.call_tool(nil, "tcp.test", {}, template) }
        assert_match message, error.message
      end
    end
  end

  def test_tcp_length_prefixes_fixed_delimiter_and_stream_framing
    { [1, "big"] => "C", [2, "little"] => "v", [4, "big"] => "N", [8, "little"] => "Q<" }.each do |(bytes, endian), packing|
      with_tcp_server(->(socket) { size = socket.read(bytes).unpack1(packing); socket.read(size); socket.write([4].pack(packing) + "pong") }) do |port|
        template = UTCP::TcpCallTemplate.new(host: "127.0.0.1", port: port, framing_strategy: "length_prefix", length_prefix_bytes: bytes, length_prefix_endian: endian)
        assert_equal "pong", UTCP::TCPProtocol.new.call_tool(nil, "tcp.test", { message: "ping" }, template)
      end
    end
    [
      [{ framing_strategy: "fixed_length", fixed_message_length: 4 }, "pong", "pong"],
      [{ framing_strategy: "delimiter", message_delimiter: '\x00', interpret_escape_sequences: true }, "pong\0", "pong"],
      [{ framing_strategy: "stream" }, "pong", "pong"]
    ].each do |options, payload, expected|
      with_tcp_server(->(socket) { socket.readpartial(4096); socket.write(payload) }) do |port|
        template = UTCP::TcpCallTemplate.new(host: "127.0.0.1", port: port, **options)
        assert_equal expected, UTCP::TCPProtocol.new.call_tool(nil, "tcp.test", {}, template)
      end
    end
  end

  def test_tcp_delimiter_eof_and_size_limit
    ["abc", "a" * 8].each do |payload|
      with_tcp_server(->(socket) { socket.readpartial(4096); socket.write(payload) }) do |port|
        template = UTCP::TcpCallTemplate.new(host: "127.0.0.1", port: port, framing_strategy: "delimiter", max_response_size: 8)
        assert_raises(UTCP::ToolCallError) { UTCP::TCPProtocol.new.call_tool(nil, "tcp.test", {}, template) }
      end
    end
  end

  def test_websocket_fragmentation_ping_pong_and_close
    responses = Queue.new
    handler = lambda do |socket|
      accept_websocket(socket)
      socket.write(websocket_frame("a", final: false) + websocket_frame("ping", opcode: 9) + websocket_frame("", opcode: 10) + websocket_frame("b", opcode: 0))
      responses << read_websocket_frame(socket)
      socket.write(websocket_frame("", opcode: 8))
      responses << read_websocket_frame(socket)
    end
    with_tcp_server(handler) do |port|
      connection = UTCP::WebSocketConnection.new("ws://127.0.0.1:#{port}", {}, nil, 0.5)
      assert_equal [1, "ab"], connection.read_message
      assert_nil connection.read_message
      assert connection.closed?
      assert_equal [10, "ping"], responses.pop
      assert_equal [8, ""], responses.pop
    ensure
      connection&.close
    end
  end

  def test_websocket_binary_and_extended_lengths_in_both_directions
    [4, 126, 65_536].each do |size|
      payload = "x" * size
      received = Queue.new
      with_tcp_server(->(socket) { accept_websocket(socket); received << read_websocket_frame(socket); socket.write(websocket_frame(payload, opcode: 2)); socket.read }) do |port|
        connection = UTCP::WebSocketConnection.new("ws://127.0.0.1:#{port}/echo?q=1", {}, nil, 1)
        connection.send_binary(payload)
        assert_equal [2, payload], connection.read_message
        assert_equal [2, payload], received.pop
      ensure
        connection&.close
      end
    end
  end

  def test_websocket_rejects_invalid_frames_and_disconnections
    [websocket_frame("x", opcode: 0), websocket_frame("x", opcode: 3), websocket_frame("a", final: false) + websocket_frame("b"), [0x81, 127, UTCP::WebSocketConnection::MAX_MESSAGE_SIZE + 1].pack("CCQ>"), "\x81\x05ab".b].each do |frame|
      with_tcp_server(->(socket) { accept_websocket(socket); socket.write(frame) }) do |port|
        connection = UTCP::WebSocketConnection.new("ws://127.0.0.1:#{port}/", {}, nil, 0.5)
        assert_raises(UTCP::ToolCallError) { connection.read_message }
      ensure
        connection&.close
      end
    end
  end

  def test_websocket_partial_frame_times_out
    with_tcp_server(->(socket) { accept_websocket(socket); socket.write("\x81\x05ab".b); socket.read }) do |port|
      connection = UTCP::WebSocketConnection.new("ws://127.0.0.1:#{port}/", {}, nil, 0.1)
      assert_raises(UTCP::TimeoutError) { connection.read_message }
    ensure
      connection&.close
    end
  end

  def test_failed_websocket_handshake_closes_the_socket
    closed = Queue.new
    with_tcp_server(->(socket) { accept_websocket(socket, response_headers: { "Sec-WebSocket-Accept" => "invalid" }); closed << socket.read }) do |port|
      assert_raises(UTCP::SecurityError) { UTCP::WebSocketConnection.new("ws://127.0.0.1:#{port}/", {}, nil, 0.1) }
      assert_equal "", Timeout.timeout(1) { closed.pop }
    end
  end
end
