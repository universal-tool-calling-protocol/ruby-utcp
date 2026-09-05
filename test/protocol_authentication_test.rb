# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/auth_transport_harness"

class ProtocolAuthenticationTest < Minitest::Test
  TYPES = %w[http sse streamable_http http_stream websocket graphql graphql_subscription grpc mcp].freeze

  def setup
    @client = UTCP::Client.new(logger: Logger.new(File::NULL))
    @harnesses = []
  end

  def teardown
    @harnesses.each { |h| h.protocol.deregister_manual(@client, h.template) }
  end

  TYPES.each do |type|
    kinds = type == "grpc" ? %i[header basic oauth] : %i[header query cookie basic oauth]
    kinds.each do |kind|
      define_method("test_#{type}_#{kind}_auth_on_discovery_calls_and_streams") do
        h = harness(type, credentials(kind))
        result = h.discover(@client)
        assert result.success?, result.errors.join("; ")
        assert_auth(h.requests.last, kind)
        refute_nil h.call(@client)
        assert_auth(h.requests.last, kind)
        refute_empty h.call(@client, streaming: true)
        assert_auth(h.requests.last, kind)
        if kind == :oauth
          assert_equal 1, h.requests.count { |request| request[:uri]&.path == "/token" }
        end
      end
    end

    define_method("test_#{type}_rejects_oauth_redirect_before_transport_call") do
      h = harness(type, credentials(:oauth))
      h.token_handler = ->(_request) { FakeHTTPResponse.new(code: 307, headers: { "Location" => "https://other.example.test/token" }) }
      assert_raises(UTCP::SecurityError) { h.call(@client) }
      assert_equal ["/token"], h.requests.map { |request| request[:uri]&.path }
    end

    define_method("test_#{type}_rejects_invalid_rotated_oauth_secret") do
      h = harness(type, credentials(:oauth))
      assert h.discover(@client).success?
      h.token_handler = ->(_request) { FakeHTTPResponse.new(code: 401) }
      changed = UTCP::CallTemplate.from_h(h.template.to_h)
      changed.auth = credentials(:oauth, client_secret: "incorrect-secret")
      assert_raises(UTCP::AuthenticationError) { h.call(@client, changed) }
      assert_equal "/token", h.requests.last[:uri]&.path
    end

    define_method("test_#{type}_rejects_unknown_auth_without_sending_request") do
      h = harness(type, UTCP::Auth.new(auth_type: "unsupported"))
      assert_raises(UTCP::AuthenticationError, UTCP::ValidationError) { h.call(@client) }
      assert_empty h.requests
    end

    %i[header cookie].each do |kind|
      next if type == "grpc" && kind == :cookie
      define_method("test_#{type}_rejects_crlf_in_#{kind}_key_before_io") do
        h = harness(type, credentials(kind, api_key: "test\r\nX-Injected: yes"))
        assert_raises(UTCP::SecurityError) { h.call(@client) }
        assert_empty h.requests
      end
    end
  end

  %w[http sse streamable_http http_stream graphql mcp].each do |type|
    [401, 403].each do |status|
      define_method("test_#{type}_reports_#{status}_as_authentication_failure") do
        h = harness(type, credentials(:basic))
        h.response_status = status
        assert_raises(UTCP::AuthenticationError) { h.call(@client) }
      end
    end
  end

  %w[sse streamable_http http_stream].each do |type|
    define_method("test_#{type}_stream_rejects_redirect_without_resending_credentials") do
      h = harness(type, credentials(:basic))
      h.redirect = "https://other.example.test/tools"
      assert_raises(UTCP::SecurityError) { h.call(@client, streaming: true) }
      assert_equal 1, h.requests.length
    end
  end

  def test_mcp_redirect_strips_session_id_and_static_credentials
    h = harness("mcp", nil)
    h.redirect = "https://other.example.test/final"
    h.protocol.define_singleton_method(:send_request) do |uri, request, _timeout|
      h.requests << { uri: uri, headers: request.each_header.to_h }
      uri.path == "/tools" ? FakeHTTPResponse.new(code: 307, headers: { "Location" => h.redirect }) : h.json({})
    end
    h.protocol.mcp_http_request(
      "#{AuthTransportHarness::ORIGIN}/tools",
      { "Authorization" => "Bearer test", "Cookie" => "sid=test" },
      h.template, { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }, "test-session"
    )
    %w[authorization cookie mcp-session-id].each do |name|
      assert h.requests.first[:headers].key?(name)
      refute h.requests.last[:headers].key?(name), name
    end
  end

  def test_mcp_new_credentials_start_new_initialized_session
    h = harness("mcp", credentials(:header))
    assert h.discover(@client).success?
    changed = UTCP::CallTemplate.from_h(h.template.to_h)
    changed.auth = credentials(:header, api_key: "rotated-key")
    refute_nil h.call(@client, changed)

    initializations = h.requests.select { |request| request[:rpc_method] == "initialize" }
    assert_equal 2, initializations.length
    assert_nil initializations.last[:headers]["mcp-session-id"]
    assert_equal "rotated-key", h.requests.last[:headers]["x-test-key"]
    refute_nil h.requests.last[:headers]["mcp-session-id"]
  end

  def test_mcp_rotated_static_headers_start_new_session
    h = harness("mcp", nil)
    h.template.servers["remote"]["headers"] = { "Authorization" => "Bearer first" }
    assert h.discover(@client).success?
    changed = UTCP::CallTemplate.from_h(h.template.to_h)
    changed.servers["remote"]["headers"]["Authorization"] = "Bearer second"
    h.call(@client, changed)
    assert_equal 2, h.requests.count { |request| request[:rpc_method] == "initialize" }
    assert_equal "Bearer second", h.requests.last[:headers]["authorization"]
  end

  def test_mcp_credential_snapshots_survive_in_place_changes_and_reuse
    h = harness("mcp", credentials(:header, api_key: +"test-key"))
    assert h.discover(@client).success?
    h.template.auth.api_key.replace("rotated-key")
    h.call(@client)
    assert_equal "rotated-key", h.requests.last[:headers]["x-test-key"]
    h.template.auth.api_key.replace("test-key")
    h.call(@client)
    assert_equal "test-key", h.requests.last[:headers]["x-test-key"]
    assert_equal 2, h.requests.count { |request| request[:rpc_method] == "initialize" }
  end

  %w[query cookie].each do |location|
    define_method("test_grpc_rejects_unsupported_#{location}_key_location") do
      h = harness("grpc", credentials(location.to_sym))
      assert_raises(UTCP::AuthenticationError) { h.call(@client) }
      assert_empty h.requests
    end
  end

  UNSUPPORTED = {
    "cli" => [UTCP::CLIProtocol, { commands: [{ command: "printf unused" }] }],
    "tcp" => [UTCP::TCPProtocol, { host: "localhost", port: 1 }],
    "udp" => [UTCP::UDPProtocol, { host: "localhost", port: 1 }],
    "text" => [UTCP::TextProtocol, { content: "{}" }],
    "file" => [UTCP::FileProtocol, { file_path: "/nonexistent-auth-test" }],
    "webrtc" => [UTCP::WebRTCProtocol, { signaling_server: "http://localhost", peer_id: "test", data_channel_name: "tools" }]
  }.freeze

  UNSUPPORTED.each do |type, (klass, options)|
    %i[header basic oauth].each do |kind|
      define_method("test_#{type}_rejects_unsupported_#{kind}_auth_for_discovery_and_calls") do
        # Factories fail if execution reaches I/O; the expected error is raised first.
        factory = ->(*_args) { raise "Unexpected transport I/O" }
        protocol = if %w[tcp udp].include?(type)
                     klass.new(socket_factory: factory)
                   elsif type == "webrtc"
                     klass.new(peer_factory: factory)
                   else
                     klass.new
                   end
        template = UTCP::CallTemplate.from_h(options.merge(call_template_type: type, auth: credentials(kind)))
        assert_raises(UTCP::AuthenticationError) { protocol.call_tool(@client, "test.echo", {}, template) }
        result = protocol.register_manual(@client, template)
        refute result.success?
        assert_match(/auth/i, result.errors.join)
      end
    end
  end

  def test_mcp_stdio_rejects_ignored_auth_before_starting_process
    template = UTCP::McpCallTemplate.new(
      auth: credentials(:basic), config: { mcpServers: { local: { command: "/nonexistent-auth-test" } } }
    )
    protocol = UTCP::MCPProtocol.new
    assert_raises(UTCP::AuthenticationError) { protocol.call_tool(@client, "#{template.name}.local.echo", {}, template) }
    result = protocol.register_manual(@client, template)
    refute result.success?
    assert_match(/auth/i, result.errors.join)
  end

  private

  def harness(type, auth)
    AuthTransportHarness.new(type, auth).tap { |h| @harnesses << h }
  end

  def credentials(kind, **overrides)
    options = case kind
              when :basic then { auth_type: "basic", username: "tester", password: "test-pass" }
              when :oauth then { auth_type: "oauth2", token_url: "https://identity.example.test/token", client_id: "tester", client_secret: "test-secret", scope: "read" }
              else { auth_type: "api_key", api_key: "test-key", var_name: "X-Test-Key", location: kind.to_s }
              end
    UTCP::Auth.from_h(options.merge(overrides))
  end

  def assert_auth(request, kind)
    case kind
    when :query
      assert_equal "test-key", URI.decode_www_form(request[:uri].query).to_h["X-Test-Key"]
    when :header then assert_equal "test-key", request[:headers]["x-test-key"]
    when :cookie then assert_equal "X-Test-Key=test-key", request[:headers]["cookie"]
    when :basic then assert_equal "Basic #{Base64.strict_encode64('tester:test-pass')}", request[:headers]["authorization"]
    when :oauth then assert_equal "Bearer token-for-test-secret", request[:headers]["authorization"]
    end
  end
end
