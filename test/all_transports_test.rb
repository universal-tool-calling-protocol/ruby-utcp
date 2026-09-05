# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

class AllTransportsTest < Minitest::Test
  OFFICIAL_TYPES = %w[
    http sse streamable_http cli websocket grpc graphql tcp udp webrtc mcp text
  ].freeze

  def test_all_twelve_official_transport_types_are_registered
    assert_empty OFFICIAL_TYPES - UTCP.call_template_types
    assert_empty OFFICIAL_TYPES - UTCP.protocol_types
  end

  def test_sse_discovers_and_streams_filtered_json_and_text_events
    protocol = Class.new(UTCP::SSEProtocol) do
      private

      def send_request(_uri, _request, _timeout)
        FakeHTTPResponse.new(
          body: JSON.generate(tools: [{ name: "watch" }]),
          headers: { "Content-Type" => "application/json" }
        )
      end

      def send_stream_request(_uri, _request, _timeout)
        yield FakeStreamingResponse.new(
          chunks: ["event: skip\ndata: 1\n\n", "event: update\ndata: {\"n\":", "2}\n\nevent: update\ndata: plain\n\n"],
          headers: { "Content-Type" => "text/event-stream" }
        )
      end
    end.new
    with_protocol("sse", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{ name: "events", call_template_type: "sse", url: "http://localhost/events", event_type: "update" }]
      })
      assert_equal [{ "n" => 2 }, "plain"], client.call_tool("events.watch")
    end
  end

  def test_streamable_http_decodes_ndjson_incrementally
    protocol = Class.new(UTCP::StreamableHTTPProtocol) do
      private

      def send_request(_uri, _request, _timeout)
        FakeHTTPResponse.new(body: JSON.generate(tools: [{ name: "generate" }]), headers: { "Content-Type" => "application/json" })
      end

      def send_stream_request(_uri, _request, _timeout)
        yield FakeStreamingResponse.new(
          chunks: ["{\"token\":\"a\"}\n{\"tok", "en\":\"b\"}\n"],
          headers: { "Content-Type" => "application/x-ndjson" }
        )
      end
    end.new
    with_protocol("streamable_http", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{ name: "stream", call_template_type: "streamable_http", url: "http://localhost/stream" }]
      })
      assert_equal [{ "token" => "a" }, { "token" => "b" }], client.call_tool("stream.generate")
    end
  end

  def test_websocket_discovers_and_calls_over_a_persistent_connection
    connection = FakeWebSocketConnection.new([
      JSON.generate(tools: [{ name: "echo" }]),
      JSON.generate("echo" => "hello")
    ])
    protocol = UTCP::WebSocketProtocol.new(connection_factory: ->(*_args) { connection })
    with_protocol("websocket", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{ name: "realtime", call_template_type: "websocket", url: "ws://localhost/socket" }]
      })
      assert_equal({ "echo" => "hello" }, client.call_tool("realtime.echo", value: "hello"))
      assert_equal({ "type" => "utcp" }, JSON.parse(connection.sent[0]))
      assert_equal({ "value" => "hello" }, JSON.parse(connection.sent[1]))
    end
  end

  def test_websocket_builds_request_target_for_generic_ws_uri
    connection = UTCP::WebSocketConnection.allocate
    connection.instance_variable_set(:@uri, URI.parse("ws://localhost/socket?token=one"))

    assert_equal "/socket?token=one", connection.send(:websocket_request_target)
    assert_equal 80, connection.send(:websocket_port)
  end

  def test_websocket_variable_inspection_does_not_close_the_active_connection
    connections = []
    protocol = UTCP::WebSocketProtocol.new(connection_factory: ->(*_args) {
      FakeWebSocketConnection.new([
        JSON.generate(tools: [{ name: "echo" }]), JSON.generate("echo" => "still connected")
      ]).tap { |connection| connections << connection }
    })
    with_protocol("websocket", protocol) do
      template = { name: "realtime", call_template_type: "websocket", url: "ws://localhost/socket",
                   auth: { auth_type: "api_key", api_key: "test-only", location: "query", var_name: "token" } }
      client = UTCP::Client.create(config: { manual_call_templates: [template] })
      begin
        assert_empty client.get_required_variables_for_manual_and_tools(template)
        assert_equal 2, connections.length
        assert connections.last.closed?
        refute connections.first.closed?
        assert_equal({ "echo" => "still connected" }, client.call_tool("realtime.echo"))
      ensure
        client.close
      end
      assert connections.all?(&:closed?)
    end
  end

  def test_graphql_introspection_creates_tools_and_query_call_returns_field
    protocol = Class.new(UTCP::GraphQLProtocol) do
      attr_reader :payloads

      def initialize
        super
        @payloads = []
      end

      private

      def send_request(_uri, request, _timeout)
        payload = JSON.parse(request.body)
        @payloads << payload
        body = if payload["query"].include?("UTCPIntrospection")
                 {
                   data: { __schema: {
                     queryType: { fields: [{
                       name: "hello", description: "Greeting",
                       args: [{ name: "name", type: { kind: "NON_NULL", ofType: { kind: "SCALAR", name: "String" } } }],
                       type: { kind: "SCALAR", name: "String" }
                     }] },
                     mutationType: nil, subscriptionType: nil, types: []
                   } }
                 }
               else
                 { data: { hello: "Hello #{payload.dig("variables", "name")}" } }
               end
        FakeHTTPResponse.new(body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
      end
    end.new
    with_protocol("graphql", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{ name: "graph", call_template_type: "graphql", url: "http://localhost/graphql" }]
      })
      assert_equal "Hello Ruby", client.call_tool("graph.hello", name: "Ruby")
      assert_includes protocol.payloads.last["query"], "$name: String!"
    end
  end

  def test_grpc_uses_utcp_protobuf_service_for_discovery_call_and_streaming
    tool = UTCP::ProtobufWire.string_field(1, "echo") + UTCP::ProtobufWire.string_field(2, "Echo")
    manual = UTCP::ProtobufWire.string_field(1, "1.0.0") + UTCP::ProtobufWire.string_field(2, tool)
    rpc = FakeRPCClient.new(manual)
    protocol = UTCP::GRPCProtocol.new(rpc_client_factory: ->(_template) { rpc })
    with_protocol("grpc", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{ name: "rpc", call_template_type: "grpc", host: "localhost", port: 50051, use_ssl: false }]
      })
      assert_equal({ "ok" => true }, client.call_tool("rpc.echo", value: 1))
      assert_equal [{ "part" => 1 }, { "part" => 2 }], client.call_tool_streaming("rpc.echo").to_a
      assert_equal "/grpcpb.UTCPService/GetManual", rpc.calls.first[0]
    end
  end

  def test_tcp_supports_length_prefix_framing
    discovery = JSON.generate(tools: [{ name: "echo" }])
    sockets = [FakeStreamSocket.new(frame(discovery)), FakeStreamSocket.new(frame("pong"))]
    protocol_class = Class.new(UTCP::TCPProtocol) do
      private

      def wait_readable!(*_args); end
    end
    protocol = protocol_class.new(socket_factory: ->(*_args) { sockets.shift })
    with_protocol("tcp", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{
          name: "socket", call_template_type: "tcp", host: "localhost", port: 9000,
          framing_strategy: "length_prefix"
        }]
      })
      assert_equal "pong", client.call_tool("socket.echo", value: 7)
    end
  end

  def test_udp_supports_multiple_datagram_responses
    discovery = FakeDatagramSocket.new([JSON.generate(tools: [{ name: "read" }])])
    invocation = FakeDatagramSocket.new(%w[first second])
    sockets = [discovery, invocation]
    protocol_class = Class.new(UTCP::UDPProtocol) do
      private

      def wait_readable!(*_args); end
    end
    protocol = protocol_class.new(socket_factory: -> { sockets.shift })
    with_protocol("udp", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{
          name: "datagrams", call_template_type: "udp", host: "localhost", port: 9001,
          number_of_response_datagrams: 2
        }]
      })
      assert_equal %w[first second], client.call_tool("datagrams.read", value: 7)
    end
  end

  def test_mcp_discovers_calls_and_exposes_resources
    session = FakeMCPSession.new
    protocol = UTCP::MCPProtocol.new(session_factory: ->(*_args) { session })
    with_protocol("mcp", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{
          name: "bridge", call_template_type: "mcp", register_resources_as_tools: true,
          config: { mcpServers: { local: { command: "unused" } } }
        }]
      })
      assert_equal({ "answer" => 42 }, client.call_tool("bridge.local.calculate", expression: "6*7"))
      assert_equal({ "contents" => [{ "text" => "readme" }] }, client.call_tool("bridge.local.resource_docs"))
      assert_includes session.notifications, "notifications/initialized"
    end
  end

  def test_mcp_stdio_session_performs_real_json_rpc_lifecycle
    protocol = UTCP::MCPProtocol.new
    with_protocol("mcp", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{
          name: "stdio", call_template_type: "mcp",
          config: {
            mcpServers: {
              fixture: {
                command: RbConfig.ruby,
                args: [File.expand_path("fixtures/mcp_server.rb", __dir__)]
              }
            }
          }
        }]
      })
      assert_equal({ "echo" => "works" }, client.call_tool("stdio.fixture.echo", message: "works"))
      client.close
    end
  end

  def test_webrtc_discovers_and_calls_through_peer_adapter
    peer = FakeWebRTCPeer.new
    protocol = UTCP::WebRTCProtocol.new(peer_factory: ->(_template) { peer })
    with_protocol("webrtc", protocol) do
      client = UTCP::Client.create(config: {
        manual_call_templates: [{
          name: "rtc", call_template_type: "webrtc", signaling_server: "http://localhost:8080",
          peer_id: "ruby", data_channel_name: "utcp"
        }]
      })
      assert_equal "hello", client.call_tool("rtc.echo", message: "hello")
      assert_equal "echo", peer.requests.first["tool"]
    end
  end

  private

  def with_protocol(type, protocol)
    original = UTCP.protocol(type)
    UTCP.register_protocol(type, protocol)
    yield
  ensure
    UTCP.register_protocol(type, original)
  end

  def frame(value)
    [value.bytesize].pack("N") + value
  end
end

class FakeWebSocketConnection
  attr_reader :sent

  def initialize(messages)
    @messages = messages
    @sent = []
    @closed = false
  end

  def send_text(value)
    @sent << value
  end

  def read_message
    value = @messages.shift
    value ? [0x1, value] : nil
  end

  def closed?
    @closed
  end

  def close
    @closed = true
  end
end

class FakeRPCClient
  attr_reader :calls

  def initialize(manual)
    @manual = manual
    @calls = []
  end

  def unary(route, payload, **_options)
    @calls << [route, payload]
    return @manual if route.end_with?("/GetManual")

    UTCP::ProtobufWire.string_field(1, JSON.generate(ok: true))
  end

  def server_stream(route, payload, **_options)
    @calls << [route, payload]
    [
      UTCP::ProtobufWire.string_field(1, JSON.generate(part: 1)),
      UTCP::ProtobufWire.string_field(1, JSON.generate(part: 2))
    ]
  end
end

class FakeStreamSocket
  attr_reader :written

  def initialize(response)
    @response = response.b
    @written = +"".b
    @closed = false
  end

  def write(value)
    @written << value
    value.bytesize
  end

  def readpartial(length)
    raise EOFError if @response.empty?

    @response.slice!(0, length)
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

class FakeDatagramSocket
  def initialize(responses)
    @responses = responses
    @closed = false
  end

  def connect(*_args); end
  def write(value); value.bytesize; end
  def recv(_length); @responses.shift; end
  def close; @closed = true; end
  def closed?; @closed; end
end

class FakeMCPSession
  attr_reader :notifications

  def initialize
    @notifications = []
  end

  def request(method, params = {})
    case method
    when "initialize" then { "protocolVersion" => "2025-06-18" }
    when "tools/list"
      { "tools" => [{ "name" => "calculate", "description" => "Calculate", "inputSchema" => { "type" => "object" } }] }
    when "resources/list"
      { "resources" => [{ "name" => "docs", "uri" => "file:///README.md" }] }
    when "tools/call"
      { "structuredContent" => { "answer" => params.dig("arguments", "expression") == "6*7" ? 42 : 0 } }
    when "resources/read"
      { "contents" => [{ "text" => "readme" }] }
    else
      {}
    end
  end

  def notify(method, _params = {})
    @notifications << method
  end

  def close; end
end

class FakeWebRTCPeer
  attr_reader :requests

  def initialize
    @requests = []
  end

  def connect
    { "tools" => [{ "name" => "echo" }] }
  end

  def request(payload, timeout:)
    @requests << payload
    payload.dig("args", "message")
  end

  def close; end
end
