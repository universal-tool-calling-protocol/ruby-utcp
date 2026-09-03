# frozen_string_literal: true

require_relative "test_helper"

class ProtocolsTest < Minitest::Test
  def setup
    @original_http_protocol = UTCP.protocol("http")
  end

  def teardown
    UTCP.register_protocol("http", @original_http_protocol)
  end

  def test_http_discovers_and_calls_tools_with_path_query_body_headers_and_auth
    endpoint = "http://localhost:4567"
    protocol = FakeHTTPProtocol.new do |request|
      case request[:target]
      when "/manual"
        manual = {
          manual_version: "1.0.0",
          utcp_version: "1.1.0",
          tools: [
            {
              name: "lookup",
              tool_call_template: {
                call_template_type: "http",
                url: "#{endpoint}/users/{id}",
                http_method: "GET"
              }
            },
            {
              name: "update",
              tool_call_template: {
                call_template_type: "http",
                url: "#{endpoint}/users/{id}",
                http_method: "POST",
                body_field: "body",
                header_fields: ["X-Trace"],
                auth: {
                  auth_type: "api_key",
                  api_key: "${TOKEN}",
                  var_name: "X-Api-Key",
                  location: "header"
                }
              }
            }
          ]
        }
        FakeHTTPResponse.new(body: JSON.generate(manual), headers: { "Content-Type" => "application/json" })
      else
        FakeHTTPResponse.new(body: JSON.generate(request), headers: { "Content-Type" => "application/json" })
      end
    end
    UTCP.register_protocol("http", protocol)

    client = UTCP::Client.create(config: {
      variables: { TOKEN: "secret" },
      manual_call_templates: [{ name: "api", call_template_type: "http", url: "#{endpoint}/manual" }]
    })

    lookup = client.call_tool("api.lookup", id: "a b/c", q: %w[one two])
    assert_includes lookup["target"], "/users/a%20b%2Fc"
    assert_includes lookup["target"], "q=one"
    assert_includes lookup["target"], "q=two"

    update = client.call_tool("api.update", id: 7, "X-Trace" => "trace", body: { active: true })
    assert_equal "POST", update["method"]
    assert_equal "trace", update["headers"]["x-trace"]
    assert_equal "secret", update["headers"]["x-api-key"]
    assert_equal({ "active" => true }, JSON.parse(update["body"]))
  end

  def test_http_follows_a_validated_loopback_redirect
    endpoint = "http://localhost:4567"
    protocol = FakeHTTPProtocol.new do |request|
      if request[:target] == "/redirect"
        FakeHTTPResponse.new(code: 302, headers: { "Location" => "/manual" })
      else
        manual = {
          utcp_version: "1.1.0",
          tools: [{ name: "x", tool_call_template: { call_template_type: "http", url: "#{endpoint}/x" } }]
        }
        FakeHTTPResponse.new(body: JSON.generate(manual), headers: { "Content-Type" => "application/json" })
      end
    end
    UTCP.register_protocol("http", protocol)

    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "redirected", call_template_type: "http", url: "#{endpoint}/redirect" }]
    })

    assert_equal ["redirected.x"], client.list_tools.map(&:name)
  end

  def test_url_security_rejects_remote_plain_http_and_userinfo
    assert_raises(UTCP::SecurityError) { UTCP::URLSecurity.validate!("http://example.com/tools") }
    assert_raises(UTCP::SecurityError) { UTCP::URLSecurity.validate!("https://user:pass@example.com/tools") }
    assert UTCP::URLSecurity.validate!("http://localhost:3000/tools")
  end

  def test_http_oauth2_client_credentials_are_cached_and_applied
    endpoint = "http://localhost:4567"
    protocol = FakeHTTPProtocol.new do |request|
      case request[:target]
      when "/manual"
        manual = {
          utcp_version: "1.1.0",
          tools: [{
            name: "secure",
            tool_call_template: {
              call_template_type: "http",
              url: "#{endpoint}/secure",
              auth: {
                auth_type: "oauth2",
                token_url: "#{endpoint}/token",
                client_id: "client",
                client_secret: "secret"
              }
            }
          }]
        }
        FakeHTTPResponse.new(body: JSON.generate(manual), headers: { "Content-Type" => "application/json" })
      when "/token"
        FakeHTTPResponse.new(
          body: JSON.generate(access_token: "token", expires_in: 300),
          headers: { "Content-Type" => "application/json" }
        )
      else
        FakeHTTPResponse.new(body: JSON.generate(request), headers: { "Content-Type" => "application/json" })
      end
    end
    UTCP.register_protocol("http", protocol)
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "oauth", call_template_type: "http", url: "#{endpoint}/manual" }]
    })

    first = client.call_tool("oauth.secure")
    second = client.call_tool("oauth.secure")

    assert_equal "Bearer token", first["headers"]["authorization"]
    assert_equal "Bearer token", second["headers"]["authorization"]
    assert_equal 1, protocol.requests.count { |request| request[:target] == "/token" }
  end

  def test_http_status_errors_include_status_and_body
    protocol = FakeHTTPProtocol.new do |request|
      if request[:target] == "/manual"
        manual = {
          utcp_version: "1.1.0",
          tools: [{ name: "broken", tool_call_template: { call_template_type: "http", url: "http://localhost:4567/broken" } }]
        }
        FakeHTTPResponse.new(body: JSON.generate(manual), headers: { "Content-Type" => "application/json" })
      else
        FakeHTTPResponse.new(code: 500, body: "failure")
      end
    end
    UTCP.register_protocol("http", protocol)
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "errors", call_template_type: "http", url: "http://localhost:4567/manual" }]
    })

    error = assert_raises(UTCP::ToolCallError) { client.call_tool("errors.broken") }
    assert_equal 500, error.status
    assert_equal "failure", error.response_body
  end

  def test_cli_argument_values_cannot_inject_shell_syntax_and_steps_share_output
    manual = {
      utcp_version: "1.1.0",
      tools: [{
        name: "safe_echo",
        tool_call_template: {
          call_template_type: "cli",
          commands: [
            { command: "printf %s UTCP_ARG_value_UTCP_END" },
            { command: "printf 'seen:%s' \"$CMD_0_OUTPUT\"" }
          ]
        }
      }]
    }
    client = UTCP::Client.create(config: {
      manual_call_templates: [{
        name: "commands",
        call_template_type: "text",
        content: JSON.generate(manual),
        allowed_communication_protocols: ["cli"]
      }]
    })

    untrusted = "ok; printf INJECTED"
    assert_equal "seen:#{untrusted}", client.call_tool("commands.safe_echo", value: untrusted)
  end

  def test_file_protocol_resolves_paths_from_root_directory
    Dir.mktmpdir do |directory|
      path = File.join(directory, "manual.json")
      File.write(path, JSON.generate(
        utcp_version: "1.1.0",
        tools: [{ name: "read", tool_call_template: { call_template_type: "file", file_path: "payload.txt" } }]
      ))
      File.write(File.join(directory, "payload.txt"), "payload")

      client = UTCP::Client.create(
        root_dir: directory,
        config: { manual_call_templates: [{ name: "local", call_template_type: "file", file_path: "manual.json" }] }
      )

      assert_equal "payload", client.call_tool("local.read")
    end
  end

  def test_text_openapi_conversion
    openapi = {
      openapi: "3.0.0",
      info: { title: "Pet API", version: "1.0" },
      servers: [{ url: "https://example.com" }],
      paths: {
        "/pets/{id}" => {
          get: {
            operationId: "getPet",
            description: "Get one pet",
            tags: ["pets"],
            parameters: [{ name: "id", in: "path", required: true, schema: { type: "string" } }],
            responses: { "200" => { content: { "application/json" => { schema: { type: "object" } } } } }
          }
        }
      }
    }

    client = UTCP::Client.create(config: {
      manual_call_templates: [{
        name: "pets",
        call_template_type: "text",
        content: JSON.generate(openapi),
        allowed_communication_protocols: %w[text http]
      }]
    })
    tool = client.list_tools.first

    assert_equal "pets.getPet", tool.name
    assert_equal "string", tool.inputs.properties["id"]["type"]
    assert_equal "object", tool.outputs.type
    assert_equal "https://example.com/pets/{id}", tool.tool_call_template.url
  end
end
