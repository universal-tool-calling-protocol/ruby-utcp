# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/local_tcp_server"
require "webrick"
require "timeout"

class AuthenticationNetworkTest < Minitest::Test
  include LocalTCPServer

  def setup
    @original_http_protocol = UTCP.protocol("http")
    UTCP.register_protocol("http", UTCP::HTTPProtocol.new)
  end

  def teardown
    UTCP.register_protocol("http", @original_http_protocol)
  end

  def with_server(handler)
    ready = Queue.new
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [],
      StartCallback: -> { ready << true }
    )
    server.mount_proc("/", &handler)
    worker = Thread.new { server.start }
    Timeout.timeout(5) { ready.pop }
    Timeout.timeout(5) { yield "http://127.0.0.1:#{server.listeners.first.addr[1]}" }
  ensure
    server.shutdown if server
    if worker
      worker.kill unless worker.join(2)
      worker.join
    end
  end

  def respond_json(response, value)
    response["Content-Type"] = "application/json"
    response.body = JSON.generate(value)
  end

  private :with_server, :respond_json

  %w[http sse streamable_http graphql mcp].each do |type|
    %i[header query cookie basic oauth].each do |kind|
      define_method("test_#{type}_sends_#{kind}_auth_over_real_http") do
        received = []
        with_server(->(request, response) {
          if request.path == "/token"
            assert_equal "test-secret", request.query["client_secret"]
            respond_json(response, access_token: "test-token", expires_in: 300)
          else
            received << request
            case type
            when "sse"
              response["Content-Type"] = "text/event-stream"
              response.body = "data: \"ok\"\n\n"
            when "streamable_http"
              response["Content-Type"] = "application/x-ndjson"
              response.body = "\"ok\"\n"
            when "graphql" then respond_json(response, data: { echo: "ok" })
            when "mcp"
              message = JSON.parse(request.body)
              if message.key?("id")
                result = message["method"] == "tools/call" ? { structuredContent: { ok: true } } : {}
                respond_json(response, jsonrpc: "2.0", id: message["id"], result: result)
              else
                response.status = 202
                response.body = ""
              end
            else respond_json(response, ok: true)
            end
          end
        }) do |origin|
          auth = network_auth(kind, origin)
          options = { name: "api", call_template_type: type, auth: auth, url: "#{origin}/tools" }
          options.merge!(operation_name: "echo", query: "query { echo }") if type == "graphql"
          options.merge!(config: { mcpServers: { remote: { url: "#{origin}/tools" } } }) if type == "mcp"
          template = UTCP::CallTemplate.from_h(options)
          protocol = { "http" => UTCP::HTTPProtocol, "sse" => UTCP::SSEProtocol,
                       "streamable_http" => UTCP::StreamableHTTPProtocol, "graphql" => UTCP::GraphQLProtocol,
                       "mcp" => UTCP::MCPProtocol }.fetch(type).new
          begin
            name = type == "mcp" ? "api.remote.echo" : "api.echo"
            refute_nil protocol.call_tool(nil, name, {}, template)
            refute_empty received
            received.each { |request| assert_network_auth(kind, request.header, request.request_uri) }
          ensure
            protocol.deregister_manual(nil, template)
          end
        end
      end
    end
  end

  %w[websocket graphql_subscription].each do |type|
    %i[header query cookie basic oauth].each do |kind|
      define_method("test_#{type}_sends_#{kind}_auth_over_real_websocket") do
        received = nil
        with_server(->(_request, response) { respond_json(response, access_token: "test-token", expires_in: 300) }) do |origin|
          with_tcp_server(->(socket) {
            subprotocol = type == "graphql_subscription" ? { "Sec-WebSocket-Protocol" => "graphql-transport-ws" } : {}
            received = accept_websocket(socket, response_headers: subprotocol)
            read_websocket_frame(socket)
            if type == "graphql_subscription"
              socket.write(websocket_frame(JSON.generate(type: "connection_ack")))
              message = JSON.parse(read_websocket_frame(socket)[1])
              socket.write(websocket_frame(JSON.generate(id: message["id"], type: "next", payload: { data: { echo: "ok" } })))
              socket.write(websocket_frame(JSON.generate(id: message["id"], type: "complete")))
            else
              socket.write(websocket_frame('"ok"'))
            end
            read_websocket_frame(socket) # Wait for the client's close before closing the TCP socket.
          }) do |port|
            auth = network_auth(kind, origin)
            if type == "websocket"
              template = UTCP::WebSocketCallTemplate.new(url: "ws://127.0.0.1:#{port}/tools", auth: auth, keep_alive: false)
              protocol = UTCP::WebSocketProtocol.new
            else
              template = UTCP::GraphQLCallTemplate.new(url: "http://127.0.0.1:#{port}/tools", auth: auth,
                                                       operation_type: "subscription", operation_name: "echo", query: "subscription { echo }")
              protocol = UTCP::GraphQLProtocol.new
            end
            result = protocol.call_tool(nil, "api.echo", {}, template)
            assert_equal(type == "websocket" ? "ok" : ["ok"], result)
            lines = received.split("\r\n")
            uri = URI.parse(lines.shift.split[1])
            headers = lines.each_with_object({}) do |line, values|
              name, value = line.split(":", 2)
              values[name.downcase] = [value.strip]
            end
            assert_network_auth(kind, headers, uri)
          end
        end
      end
    end

    [401, 403].each do |status|
      define_method("test_#{type}_maps_handshake_#{status}_to_authentication_error") do
        with_tcp_server(->(socket) {
          read_http_request(socket)
          socket.write("HTTP/1.1 #{status} Denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }) do |port|
          if type == "websocket"
            template = UTCP::WebSocketCallTemplate.new(url: "ws://127.0.0.1:#{port}/tools")
            protocol = UTCP::WebSocketProtocol.new
          else
            template = UTCP::GraphQLCallTemplate.new(url: "http://127.0.0.1:#{port}/tools", operation_type: "subscription")
            protocol = UTCP::GraphQLProtocol.new
          end
          assert_raises(UTCP::AuthenticationError) { protocol.call_tool(nil, "api.echo", {}, template) }
        end
      end
    end
  end

  def network_auth(kind, origin)
    case kind
    when :basic then { auth_type: "basic", username: "tester", password: "test-pass" }
    when :oauth then { auth_type: "oauth2", token_url: "#{origin}/token", client_id: "tester", client_secret: "test-secret" }
    else { auth_type: "api_key", location: kind.to_s, var_name: "X-Test-Key", api_key: "test-key" }
    end
  end

  def assert_network_auth(kind, headers, uri)
    case kind
    when :query then assert_equal "test-key", URI.decode_www_form(uri.query).to_h["X-Test-Key"]
    when :header then assert_equal ["test-key"], headers["x-test-key"]
    when :cookie then assert_equal ["X-Test-Key=test-key"], headers["cookie"]
    when :basic then assert_equal ["Basic #{Base64.strict_encode64('tester:test-pass')}"], headers["authorization"]
    when :oauth then assert_equal ["Bearer test-token"], headers["authorization"]
    end
  end

  private :network_auth, :assert_network_auth

  def test_explicit_authorization_and_cookie_are_not_sent_to_other_origin
    received = nil
    with_server(->(request, response) {
      received = request.header
      respond_json(response, ok: true)
    }) do |target|
      with_server(->(_request, response) {
        response.status = 302
        response["Location"] = "#{target}/capture"
      }) do |origin|
        template = UTCP::HttpCallTemplate.new(
          url: "#{origin}/resource",
          headers: { "Authorization" => "Bearer test-only-token", "Cookie" => "session=test-only-session" }
        )
        assert_equal({ "ok" => true }, UTCP::HTTPProtocol.new.call_tool(nil, "api.resource", {}, template))
        assert_empty received.keys & %w[authorization cookie], "Credential headers arrived at a different local origin"
      end
    end
  end

  [307, 308].each do |status|
    define_method("test_oauth_#{status}_does_not_send_secret_to_other_origin") do
      received = nil
      with_server(->(request, response) {
        received = URI.decode_www_form(request.body.to_s).to_h
        respond_json(response, access_token: "test-only-token", expires_in: 300)
      }) do |target|
        with_server(->(request, response) {
          if request.path == "/token"
            response.status = status
            response["Location"] = "#{target}/token"
          else
            respond_json(response, ok: true)
          end
        }) do |origin|
          template = UTCP::HttpCallTemplate.new(
            url: "#{origin}/resource",
            auth: { auth_type: "oauth2", token_url: "#{origin}/token", client_id: "test-client", client_secret: "test-only-secret" }
          )
          assert_raises(UTCP::SecurityError) do
            UTCP::HTTPProtocol.new.call_tool(nil, "api.resource", {}, template)
          end
          assert_nil received, "OAuth token request arrived at a different local origin"
        end
      end
    end
  end

  def test_separate_client_with_invalid_secret_cannot_use_first_clients_cached_token
    token_requests = 0
    issued_tokens = 0
    calls = 0
    with_server(->(request, response) {
      if request.path == "/token"
        token_requests += 1
        fields = URI.decode_www_form(request.body.to_s).to_h
        if fields["client_secret"] == "test-correct-secret"
          issued_tokens += 1
          respond_json(response, access_token: "test-cached-token", expires_in: 300)
        else
          response.status = 401
          respond_json(response, error: "invalid_client")
        end
      else
        calls += 1
        response.status = 401 unless request["Authorization"] == "Bearer test-cached-token"
        respond_json(response, ok: true)
      end
    }) do |origin|
      manual = {
        utcp_version: "1.1.0",
        tools: [{
          name: "resource",
          tool_call_template: {
            call_template_type: "http", url: "#{origin}/resource",
            auth: { auth_type: "oauth2", token_url: "#{origin}/token", client_id: "test-client", client_secret: "${SECRET}" }
          }
        }]
      }
      clients = %w[test-correct-secret test-incorrect-secret].map do |secret|
        UTCP::Client.create(config: {
          variables: { SECRET: secret },
          manual_call_templates: [{
            name: "api", call_template_type: "text", content: JSON.generate(manual),
            allowed_communication_protocols: ["http"]
          }]
        })
      end
      begin
        assert_equal({ "ok" => true }, clients.first.call_tool("api.resource"))
        assert_equal 1, issued_tokens
        assert_raises(UTCP::AuthenticationError) { clients.last.call_tool("api.resource") }
        assert_equal 2, token_requests
        assert_equal 1, calls
      ensure
        clients.each(&:close)
      end
    end
  end
end
