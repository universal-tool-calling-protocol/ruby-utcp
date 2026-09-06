# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/local_tcp_server"
require "rbconfig"

class ResponseLimitsTest < Minitest::Test
  include LocalTCPServer

  NETWORK_TEMPLATES = {
    http: { url: "https://example.test/" }, sse: { url: "https://example.test/" },
    streamable_http: { url: "https://example.test/" }, websocket: { url: "wss://example.test/" },
    grpc: { host: "localhost", port: 1234 }, graphql: { url: "https://example.test/" },
    tcp: { host: "localhost", port: 1234 }, udp: { host: "localhost", port: 1234 },
    webrtc: { signaling_server: "https://example.test/", peer_id: "test", data_channel_name: "tools" },
    mcp: { config: { mcpServers: { server: { command: "unused" } } } }
  }.freeze

  def template(type, **options)
    UTCP::CallTemplate.from_h(NETWORK_TEMPLATES.fetch(type).merge(call_template_type: type.to_s, **options))
  end

  def test_every_network_template_validates_and_roundtrips_response_limits
    NETWORK_TEMPLATES.each_key do |type|
      default = template(type)
      assert_kind_of UTCP::ResponseLimits, default, type.to_s
      assert_equal UTCP::ResponseLimits::DEFAULT_MAX_RESPONSE_BYTES, default.max_response_bytes
      limited = template(type, max_response_bytes: 7)
      assert_equal 7, UTCP::CallTemplate.from_h(limited.to_h).max_response_bytes, type.to_s
      assert_raises(UTCP::ValidationError) { template(type, max_response_bytes: 0) }
      assert_raises(UTCP::ValidationError) { template(type, max_response_bytes: -1) }
    end
    [UTCP::FileCallTemplate, UTCP::CliCallTemplate, UTCP::TextCallTemplate].each do |klass|
      refute_includes klass.ancestors, UTCP::ResponseLimits
    end
    text = UTCP::TextCallTemplate.new(content: "ą" * 10, max_response_bytes: 1)
    assert_equal "ą" * 10, UTCP::TextProtocol.new.call_tool(nil, "text", {}, text)
  end

  def test_tcp_enforces_exact_byte_boundary_in_every_framing_mode
    %w[length_prefix delimiter fixed_length stream].each do |mode|
      [4, 5].each do |length|
        payload = "x" * length
        wire = case mode
               when "length_prefix" then [length].pack("N") + payload
               when "delimiter" then payload + "\r\n"
               else payload
               end
        accepted = Queue.new
        handler = lambda do |socket|
          accepted << true
          socket.readpartial(1024)
          socket.write(wire)
        end
        with_tcp_server(handler) do |port|
          limited = template(:tcp, host: "127.0.0.1", port: port, framing_strategy: mode,
                             fixed_message_length: length, message_delimiter: "\r\n", max_response_bytes: 4)
          if length == 4
            assert_equal payload, UTCP::TCPProtocol.new.call_tool(nil, "test", {}, limited), mode
          else
            error = assert_raises(UTCP::ToolCallError) { UTCP::TCPProtocol.new.call_tool(nil, "test", {}, limited) }
            assert_match(/max_response_bytes/, error.message, mode)
          end
          Timeout.timeout(1) { accepted.pop }
        end
      end
    end
  end

  def test_tcp_rejects_declared_oversize_before_reading_payload
    handler = ->(socket) { socket.readpartial(1024); socket.write([100_000].pack("N")); socket.read }
    with_tcp_server(handler) do |port|
      limited = template(:tcp, host: "127.0.0.1", port: port, framing_strategy: "length_prefix", max_response_bytes: 4)
      assert_raises(UTCP::ToolCallError) { UTCP::TCPProtocol.new.call_tool(nil, "test", {}, limited) }
    end
  end

  def test_udp_shares_byte_budget_across_datagrams
    [4, 3].each do |limit|
      server = UDPSocket.new
      server.bind("127.0.0.1", 0)
      worker = Thread.new do
        _request, address = server.recvfrom(65_535)
        2.times { server.send("ą", 0, address[3], address[1]) }
      end
      begin
        limited = template(:udp, host: "127.0.0.1", port: server.addr[1], number_of_response_datagrams: 2,
                           max_response_bytes: limit, timeout: 1000)
        if limit == 4
          assert_equal ["ą", "ą"], UTCP::UDPProtocol.new.call_tool(nil, "test", {}, limited)
        else
          assert_raises(UTCP::ToolCallError) { UTCP::UDPProtocol.new.call_tool(nil, "test", {}, limited) }
        end
      ensure
        worker.kill.join unless worker.join(1)
        server.close
      end
    end
  end

  def test_websocket_fragment_budget_and_oversized_frame_headers_close_connection
    [websocket_frame("ą", final: false) + websocket_frame("ą", opcode: 0),
     [0x81, 127, 100_000].pack("CCQ>")].each do |wire|
      closed = Queue.new
      handler = lambda do |socket|
        accept_websocket(socket)
        read_websocket_frame(socket)
        socket.write(wire)
        closed << read_websocket_frame(socket).first
      end
      with_tcp_server(handler) do |port|
        limited = template(:websocket, url: "ws://127.0.0.1:#{port}/", max_response_bytes: 3, timeout: 1)
        error = assert_raises(UTCP::ToolCallError) { UTCP::WebSocketProtocol.new.call_tool(nil, "test", {}, limited) }
        assert_match(/max_response_bytes/, error.message)
        assert_equal 8, Timeout.timeout(1) { closed.pop }
      end
    end
  end

  class RPCClient
    attr_reader :reads, :finished
    def initialize(response)
      @response = response
      @reads = 0
    end
    def unary(*, **); @response; end
    def server_stream(*, **)
      Enumerator.new do |yielder|
        begin
          3.times { @reads += 1; yielder << @response }
        ensure
          @finished = true
        end
      end
    end
  end

  def test_grpc_checks_raw_protobuf_before_decoding_and_sums_stream_messages
    response = UTCP::ProtobufWire.string_field(1, '"ą"')
    rpc = RPCClient.new(response)
    protocol = UTCP::GRPCProtocol.new(rpc_client_factory: ->(_template) { rpc })
    limited = template(:grpc, max_response_bytes: response.bytesize)
    assert_equal "ą", protocol.call_tool(nil, "test", {}, limited)
    limited.max_response_bytes -= 1
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, limited) }
    limited.max_response_bytes = response.bytesize * 2
    values = []
    assert_raises(UTCP::ToolCallError) do
      protocol.call_tool_streaming(nil, "test", {}, limited).each { |value| values << value }
    end
    assert_equal ["ą", "ą"], values
    assert_equal 3, rpc.reads
    assert rpc.finished
  end

  def test_graphql_and_mcp_http_reject_oversized_body_before_parsing
    [UTCP::GraphQLProtocol.new, UTCP::MCPProtocol.new].each do |protocol|
      protocol.define_singleton_method(:send_request) do |_uri, _request, _timeout|
        FakeHTTPResponse.new(body: "invalid JSON" * 10)
      end
      error = assert_raises(UTCP::ToolCallError) do
        if protocol.is_a?(UTCP::GraphQLProtocol)
          protocol.call_tool(nil, "test", {}, template(:graphql, max_response_bytes: 8))
        else
          protocol.mcp_http_request("https://example.test/", {}, template(:mcp, max_response_bytes: 8), {}, nil)
        end
      end
      assert_match(/max_response_bytes/, error.message)
    end
  end

  class Subscription
    attr_accessor :max_response_bytes
    attr_reader :closed, :reads
    def initialize; @reads = 0; end
    def send_text(message)
      @id = JSON.parse(message)["id"]
    end
    def read_message
      @reads += 1
      value = if @reads == 1
                { "type" => "connection_ack" }
              else
                { "id" => @id, "type" => "next", "payload" => { "data" => { "test" => "ą" } } }
              end
      [1, JSON.generate(value)]
    end
    def close; @closed = true; end
  end

  def test_graphql_subscription_shares_budget_and_closes_on_limit_or_early_break
    [false, true].each do |early|
      connection = Subscription.new
      protocol = UTCP::GraphQLProtocol.new(websocket_factory: ->(*) { connection })
      limited = template(:graphql, operation_type: "subscription", max_response_bytes: 150)
      stream = protocol.call_tool_streaming(nil, "test", {}, limited)
      if early
        assert_equal ["ą"], stream.take(1)
        assert_equal 2, connection.reads
      else
        assert_raises(UTCP::ToolCallError) { stream.to_a }
        assert_equal 3, connection.reads
      end
      assert connection.closed
      assert_operator connection.max_response_bytes, :<, 150
    end
  end

  def test_mcp_stdio_counts_notifications_and_partial_lines_in_the_same_budget
    script = <<~'RUBY'
      require "json"
      $stdout.sync = true
      request = JSON.parse($stdin.gets)
      4.times { puts JSON.generate(jsonrpc: "2.0", method: "progress") }
      print "x" * 128
      sleep 5
    RUBY
    session = UTCP::MCPStdioSession.new({ "command" => RbConfig.ruby, "args" => ["-e", script] }, 1,
                                       max_response_bytes: 128)
    error = assert_raises(UTCP::Error) { session.request("test") }
    assert_match(/max_response_bytes/, error.message)
  ensure
    session&.close
  end

  class MCPSession
    attr_reader :closed, :pages
    attr_accessor :large
    def initialize; @pages = 0; end
    def request(method, _params = {})
      return {} if method == "initialize"
      return { "structuredContent" => "x" * 200 } if large
      @pages += 1
      { "tools" => [{ "name" => "tool_#{@pages}" }], "nextCursor" => @pages.to_s }
    end
    def notify(*); end
    def close; @closed = true; end
  end

  def test_mcp_custom_results_and_pagination_are_bounded
    session = MCPSession.new
    protocol = UTCP::MCPProtocol.new(session_factory: ->(*) { session })
    limited = template(:mcp, max_response_bytes: 100)
    result = protocol.register_manual(nil, limited)
    refute result.success?
    assert_match(/max_response_bytes/, result.errors.join)
    assert_equal 3, session.pages
    assert session.closed
    session.large = true
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "server.test", {}, limited) }
  ensure
    protocol&.deregister_manual(nil, limited) if limited
  end

  def test_webrtc_custom_peer_results_and_signaling_body_are_bounded
    peer = Object.new
    peer.define_singleton_method(:request) { |*, **| "x" * 100 }
    protocol = UTCP::WebRTCProtocol.new(peer_factory: ->(*) { peer })
    assert_raises(UTCP::ToolCallError) do
      protocol.call_tool(nil, "test", {}, template(:webrtc, max_response_bytes: 10))
    end

    handler = lambda do |socket|
      request = read_http_request(socket)
      socket.read(request[/Content-Length:\s*(\d+)/i, 1].to_i)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n" + "x" * 64)
      socket.read
    end
    with_tcp_server(handler) do |port|
      peer = UTCP::WebRTCPeer.allocate
      peer.instance_variable_set(:@template, template(:webrtc, signaling_server: "http://127.0.0.1:#{port}",
                                                    max_response_bytes: 32, timeout: 1))
      assert_raises(UTCP::ToolCallError) { peer.send(:post_json, "connect", {}) }
    end
  end
end
