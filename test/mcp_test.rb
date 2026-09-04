# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "timeout"

class MCPTest < Minitest::Test
  class Session
    attr_reader :calls, :server
    attr_accessor :closed

    def initialize(server, &handler)
      @server = server
      @handler = handler
      @calls = []
      @closed = false
    end

    def request(method, params = {})
      raise "session closed" if closed

      calls << [method, params]
      return @handler.call(method, params) if @handler

      case method
      when "tools/list" then { "tools" => [{ "name" => "echo" }] }
      when "resources/list" then { "resources" => [{ "name" => "docs", "uri" => "docs://#{server}" }] }
      when "resources/read" then { "contents" => [{ "uri" => params.fetch("uri") }] }
      when "tools/call" then { "content" => [{ "type" => "text", "text" => server }] }
      else {}
      end
    end

    def notify(*); end

    def close
      @closed = true
    end
  end

  def setup
    @original_protocol = UTCP.protocol("mcp")
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    UTCP.register_protocol("mcp", @original_protocol)
  end

  def client(server = "server-a", resources: false)
    UTCP::Client.create(config: {
      manual_call_templates: [{
        name: "bridge", call_template_type: "mcp", register_resources_as_tools: resources,
        config: { mcpServers: { local: { command: server } } }
      }]
    }).tap { |value| @clients << value }
  end

  def use_session(session)
    UTCP.register_protocol("mcp", UTCP::MCPProtocol.new(session_factory: ->(*_args) { session }))
  end

  def test_sessions_resources_and_close_are_isolated_between_clients
    sessions = []
    UTCP.register_protocol("mcp", UTCP::MCPProtocol.new(session_factory: ->(_name, config, _template) {
      Session.new(config.fetch("command")).tap { |session| sessions << session }
    }))
    first = client("server-a", resources: true)
    second = client("server-b", resources: true)

    assert_equal "server-a", first.call_tool("bridge.local.echo")
    assert_equal "server-b", second.call_tool("bridge.local.echo")
    assert_equal "docs://server-a", first.call_tool("bridge.local.resource_docs")["contents"].first["uri"]
    assert_equal "docs://server-b", second.call_tool("bridge.local.resource_docs")["contents"].first["uri"]

    first.close
    assert sessions.first.closed
    refute sessions.last.closed
    assert_equal "server-b", second.call_tool("bridge.local.echo")
    assert_equal 2, sessions.length
    second.close
    assert sessions.last.closed
  end

  def test_discovers_all_pages_including_an_empty_cursor
    session = Session.new("paged") do |method, params|
      case method
      when "tools/list"
        params.key?("cursor") ? { "tools" => [{ "name" => "second" }] } :
          { "tools" => [{ "name" => "first" }], "nextCursor" => "" }
      when "resources/list"
        params.key?("cursor") ? { "resources" => [{ "name" => "second", "uri" => "docs://second" }] } :
          { "resources" => [{ "name" => "first", "uri" => "docs://first" }], "nextCursor" => "next" }
      else {}
      end
    end
    use_session(session)
    registered = client(resources: true)

    assert registered.registration_results.first.success?
    assert_equal %w[bridge.local.first bridge.local.second bridge.local.resource_first bridge.local.resource_second],
                 registered.list_tools.map(&:name)
    assert_includes session.calls, ["tools/list", { "cursor" => "" }]
    assert_includes session.calls, ["resources/list", { "cursor" => "next" }]
  end

  def test_repeated_pagination_cursor_fails_registration_and_closes_session
    session = Session.new("loop") do |method, _params|
      method == "tools/list" ? { "tools" => [], "nextCursor" => "again" } : {}
    end
    use_session(session)
    registered = client

    refute registered.registration_results.first.success?
    assert_match(/repeated cursor/, registered.registration_results.first.errors.join)
    assert_empty registered.list_tools
    assert session.closed
    assert_equal 2, session.calls.count { |method, _params| method == "tools/list" }
  end

  def test_tool_error_is_not_unwrapped_as_a_success_even_with_structured_content
    payload = {
      "isError" => true,
      "structuredContent" => { "reason" => "denied" },
      "content" => [{ "type" => "text", "text" => "permission denied" }]
    }
    session = Session.new("errors") do |method, _params|
      case method
      when "tools/list" then { "tools" => [{ "name" => "fail" }] }
      when "tools/call" then payload
      else {}
      end
    end
    use_session(session)
    registered = client

    error = assert_raises(UTCP::ToolCallError) { registered.call_tool("bridge.local.fail") }
    assert_equal "bridge.local.fail", error.tool_name
    assert_match(/permission denied/, error.message)
    assert_equal payload, error.response_body
  end

  def test_http_session_tracks_session_id_and_propagates_tool_errors
    requests = []
    protocol_class = Class.new(UTCP::MCPProtocol) do
      define_method(:send_request) do |_uri, request, _timeout|
        message = JSON.parse(request.body)
        requests << [message, request]
        if message["method"] == "notifications/initialized"
          FakeHTTPResponse.new(code: 202)
        else
          result = case message["method"]
                   when "tools/list" then { "tools" => [{ "name" => "echo" }] }
                   when "tools/call"
                     if message.dig("params", "arguments", "fail")
                       { "isError" => true, "content" => [{ "type" => "text", "text" => "denied over HTTP" }] }
                     else
                       { "isError" => false, "structuredContent" => { "ok" => true } }
                     end
                   else {}
                   end
          FakeHTTPResponse.new(
            body: JSON.generate(jsonrpc: "2.0", id: message["id"], result: result),
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-123" }
          )
        end
      end
    end
    UTCP.register_protocol("mcp", protocol_class.new)
    registered = UTCP::Client.create(config: {
      manual_call_templates: [{
        name: "bridge", call_template_type: "mcp",
        config: { mcpServers: { local: { url: "http://localhost:5678/mcp", headers: { "X-Test" => "yes" } } } }
      }]
    })
    @clients << registered

    assert registered.registration_results.first.success?
    assert_equal({ "ok" => true }, registered.call_tool("bridge.local.echo"))
    error = assert_raises(UTCP::ToolCallError) { registered.call_tool("bridge.local.echo", fail: true) }
    assert_match(/denied over HTTP/, error.message)
    assert_nil requests.first.last["Mcp-Session-Id"]
    requests.drop(1).each { |_message, request| assert_equal "session-123", request["Mcp-Session-Id"] }
    assert_equal "yes", requests.first.last["X-Test"]
  end

  def test_http_sse_matches_response_id_and_preserves_protocol_errors
    template = UTCP::McpCallTemplate.new(name: "bridge", config: { mcpServers: { local: { url: "http://localhost:5678/mcp" } } })
    protocol = Object.new
    protocol.define_singleton_method(:mcp_http_request) do |_url, _headers, _template, message, _session_id|
      notifications = JSON.generate(jsonrpc: "2.0", method: "notifications/progress")
      matching = { "jsonrpc" => "2.0", "id" => message["id"] }
      if message["method"] == "fail"
        matching["error"] = { "code" => -32603, "message" => "internal error" }
      else
        matching["result"] = { "ok" => true }
      end
      {
        content_type: "text/event-stream", session_id: nil,
        body: "data: #{notifications}\n\ndata: #{JSON.generate(matching)}\n\ndata: #{notifications}\n\n"
      }
    end
    session = UTCP::MCPHTTPSession.new({ "url" => "http://localhost:5678/mcp" }, template, protocol)

    assert_equal({ "ok" => true }, session.request("test"))
    error = assert_raises(UTCP::ToolCallError) { session.request("fail") }
    assert_match(/internal error/, error.message)
  end
end

class MCPStdioTest < Minitest::Test
  def with_server(script, timeout: 2, **options)
    session = UTCP::MCPStdioSession.new(
      { "command" => RbConfig.ruby, "args" => ["-rjson", "-e", "$stdout.sync = true; #{script}"] },
      timeout, **options
    )
    yield session
  ensure
    session.close if session
  end

  def test_reads_fragmented_utf8_and_multiple_messages
    with_server(<<~RUBY) do |session|
      2.times do
        request = JSON.parse($stdin.gets)
        message = JSON.generate(jsonrpc: "2.0", method: "notifications/progress") + "\n" +
                  JSON.generate(jsonrpc: "2.0", id: request["id"], result: "zażółć") + "\n"
        message.bytes.each_slice(7) { |bytes| $stdout.write(bytes.pack("C*")) }
      end
    RUBY
      assert_equal "zażółć", session.request("test")
      assert_equal "zażółć", session.request("test")
    end
  end

  def test_partial_line_cannot_bypass_timeout
    with_server('$stdin.gets; print \'{"jsonrpc":"2.0"\'; sleep 5', timeout: 0.2) do |session|
      Timeout.timeout(3) do
        assert_raises(UTCP::TimeoutError) { session.request("test") }
      end
    end
  end

  def test_notifications_do_not_restart_request_deadline
    with_server(<<~RUBY, timeout: 0.2) do |session|
      $stdin.gets
      100.times do
        puts JSON.generate(jsonrpc: "2.0", method: "notifications/progress")
        sleep 0.01
      end
      sleep 5
    RUBY
      Timeout.timeout(3) do
        assert_raises(UTCP::TimeoutError) { session.request("test") }
      end
    end
  end

  def test_server_not_reading_stdin_cannot_block_writes_forever
    with_server("sleep 5", timeout: 0.2) do |session|
      Timeout.timeout(3) do
        assert_raises(UTCP::TimeoutError) { session.request("test", "data" => "x" * (2 * 1024 * 1024)) }
      end
    end
  end

  def test_rejects_oversized_incoming_line_before_newline
    with_server('$stdin.gets; print "x" * 256; sleep 5', max_message_bytes: 128) do |session|
      error = assert_raises(UTCP::SerializerValidationError) { session.request("test") }
      assert_match(/exceeds 128 bytes/, error.message)
    end
  end

  def test_accepts_message_at_byte_limit
    response = JSON.generate(jsonrpc: "2.0", id: 1, result: "x" * 64) + "\n"
    with_server("$stdin.gets; print #{response.dump}", max_message_bytes: response.bytesize) do |session|
      assert_equal "x" * 64, session.request("test")
    end
  end

  def test_rejects_oversized_outgoing_message
    with_server("sleep 5", max_message_bytes: 128) do |session|
      assert_raises(UTCP::SerializerValidationError) { session.request("test", "data" => "x" * 128) }
    end
  end

  def test_rejects_non_object_response
    with_server('$stdin.gets; puts "[]"') do |session|
      assert_raises(UTCP::SerializerValidationError) { session.request("test") }
    end
  end

  def test_drains_stderr_while_retaining_only_a_bounded_tail
    output = nil
    with_server(<<~RUBY) do |session|
      request = JSON.parse($stdin.gets)
      $stderr.write("x" * #{UTCP::MCPStdioSession::MAX_STDERR_BYTES * 3} + "TAIL")
      puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: "done")
    RUBY
      assert_equal "done", session.request("test")
      session.close
      output = session.stderr_output
    end
    assert_equal UTCP::MCPStdioSession::MAX_STDERR_BYTES, output.bytesize
    assert output.end_with?("TAIL")
  end
end
