# frozen_string_literal: true

# Intercepts only the I/O boundary; production discovery, auth, session and
# serialization code still runs. No native gems or external servers are needed.
class AuthTransportHarness
  ORIGIN = "https://api.example.test"
  attr_reader :protocol, :template, :requests, :connections
  attr_accessor :phase, :token_handler, :response_status, :redirect

  def initialize(type, auth)
    @type = type
    @requests = []
    @connections = []
    @phase = :call
    @response_status = 200
    options = { name: "api", call_template_type: type == "graphql_subscription" ? "graphql" : type, auth: auth }
    case type
    when "grpc"
      options.merge!(host: "api.example.test", port: 443)
      @protocol = UTCP::GRPCProtocol.new(rpc_client_factory: ->(_template) { RPC.new(self) })
    when "websocket"
      options.merge!(url: "wss://api.example.test/tools")
      @protocol = UTCP::WebSocketProtocol.new(connection_factory: ->(*args) { websocket(*args) })
    when "graphql", "graphql_subscription"
      options.merge!(url: "#{ORIGIN}/tools", operation_name: "echo", query: "query { echo }")
      options.merge!(operation_type: "subscription", query: "subscription { echo }") if type == "graphql_subscription"
      @protocol = UTCP::GraphQLProtocol.new(websocket_factory: ->(*args) { websocket(*args) })
    when "mcp"
      options.merge!(config: { mcpServers: { remote: { url: "#{ORIGIN}/tools", transport: "http" } } })
      @protocol = UTCP::MCPProtocol.new
    else
      options.merge!(url: "#{ORIGIN}/tools")
      klass = { "http" => UTCP::HTTPProtocol, "sse" => UTCP::SSEProtocol,
                "streamable_http" => UTCP::StreamableHTTPProtocol, "http_stream" => UTCP::StreamableHTTPProtocol }.fetch(type)
      @protocol = klass.new
    end
    harness = self
    @protocol.define_singleton_method(:send_request) { |uri, request, _timeout| harness.http(uri, request) }
    @protocol.define_singleton_method(:send_stream_request) do |uri, request, _timeout, &block|
      block.call(harness.http(uri, request, streaming: true))
    end
    @template = UTCP::CallTemplate.from_h(options)
  end

  def call(client, template = @template, streaming: false)
    name = @type == "mcp" ? "api.remote.echo" : "api.echo"
    @phase = :call
    if streaming
      protocol.call_tool_streaming(client, name, {}, template).to_a
    else
      protocol.call_tool(client, name, {}, template)
    end
  end

  def discover(client)
    @phase = :discovery
    protocol.register_manual(client, template)
  end

  def json(value = nil, status: 200, headers: {}, **fields)
    value = fields if value.nil?
    FakeHTTPResponse.new(code: status, body: JSON.generate(value),
                         headers: { "Content-Type" => "application/json" }.merge(headers))
  end

  def http(uri, request, streaming: false)
    details = { uri: uri, headers: request.each_header.to_h, body: request.body, method: request.method }
    requests << details
    if uri.path == "/token"
      return token_handler.call(details) if token_handler
      secret = URI.decode_www_form(request.body).to_h.fetch("client_secret")
      return json({ "access_token" => "token-for-#{secret}", "expires_in" => 300 })
    end
    return FakeHTTPResponse.new(code: 307, headers: { "Location" => redirect }) if redirect
    return FakeHTTPResponse.new(code: response_status) unless response_status == 200
    if @type == "mcp"
      message = JSON.parse(request.body)
      details[:rpc_method] = message["method"]
      return FakeHTTPResponse.new(code: 202) unless message.key?("id")
      result = case message["method"]
               when "tools/list" then { "tools" => [{ "name" => "echo" }] }
               when "tools/call" then { "structuredContent" => { "ok" => true } }
               else {}
               end
      return json({ "jsonrpc" => "2.0", "id" => message["id"], "result" => result },
                  headers: { "MCP-Session-Id" => "session-for-#{request['Authorization'] || request['X-Test-Key']}" })
    end
    if @type.start_with?("graphql")
      schema = { "queryType" => { "fields" => [{ "name" => "echo", "args" => [], "type" => { "kind" => "SCALAR", "name" => "String" } }] }, "types" => [] }
      return json("data" => phase == :discovery ? { "__schema" => schema } : { "echo" => "ok" })
    end
    if streaming
      chunks = @type == "sse" ? ["data: \"ok\"\n\n"] : ["\"ok\"\n"]
      content_type = @type == "sse" ? "text/event-stream" : "application/x-ndjson"
      return FakeStreamingResponse.new(chunks: chunks, headers: { "Content-Type" => content_type })
    end
    phase == :discovery ? json(manual) : json("ok" => true)
  end

  def manual
    { "utcp_version" => "1.1.0", "tools" => [{ "name" => "echo", "tool_call_template" => template.to_h }] }
  end

  def websocket(url, headers, subprotocol, _timeout)
    requests << { uri: URI.parse(url), headers: headers.transform_keys(&:downcase), method: "GET" }
    Connection.new(self, subprotocol).tap { |connection| connections << connection }
  end

  class Connection
    attr_reader :sent
    def initialize(harness, subprotocol)
      @harness, @subprotocol, @sent = harness, subprotocol, []
    end

    def send_text(value)
      @sent << JSON.parse(value)
    end

    def read_message
      if @subprotocol == "graphql-transport-ws"
        if sent.last["type"] == "connection_init"
          [1, JSON.generate("type" => "connection_ack")]
        elsif !@delivered
          @delivered = true
          [1, JSON.generate("id" => sent.last["id"], "type" => "next", "payload" => { "data" => { "echo" => "ok" } })]
        else
          [1, JSON.generate("id" => sent.last["id"], "type" => "complete")]
        end
      else
        [1, JSON.generate(@harness.phase == :discovery ? @harness.manual : "ok")]
      end
    end

    def close; @closed = true; end
    def closed?; !!@closed; end
  end

  class RPC
    def initialize(harness); @harness = harness; end

    def unary(route, _payload, **options)
      @harness.requests << { headers: options.fetch(:metadata), method: route }
      if route.end_with?("/GetManual")
        UTCP::ProtobufWire.string_field(1, "1.0.0") +
          UTCP::ProtobufWire.string_field(2, UTCP::ProtobufWire.string_field(1, "echo") +
            UTCP::ProtobufWire.string_field(2, "Echo"))
      else
        UTCP::ProtobufWire.string_field(1, '"ok"')
      end
    end

    def server_stream(route, payload, **options)
      [unary(route, payload, **options)]
    end
  end
end
