# frozen_string_literal: true

require_relative "test_helper"

class ModelsTest < Minitest::Test
  def test_json_schema_preserves_standard_and_extension_fields
    schema = UTCP::JsonSchema.from_h(
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "x-vendor" => true
    )

    assert_equal "object", schema.type
    assert_equal "https://json-schema.org/draft/2020-12/schema", schema.schema_
    assert_equal true, schema["x-vendor"]
    assert_equal true, schema.to_h["x-vendor"]
  end

  def test_tool_and_manual_round_trip
    manual_hash = {
      manual_version: "1.0.0",
      utcp_version: "1.1.0",
      info: { title: "Demo", version: "2.0" },
      tools: [{
        name: "echo",
        description: "Echo input",
        inputs: { type: "object" },
        outputs: { type: "string" },
        tags: ["text"],
        tool_call_template: { call_template_type: "text", content: "hello" }
      }]
    }

    manual = UTCP::Manual.from_h(manual_hash)

    assert_equal "Demo", manual.info["title"]
    assert_equal "echo", manual.tools.first.name
    assert_instance_of UTCP::TextCallTemplate, manual.tools.first.tool_call_template
    assert_equal manual.to_h, UTCP::Manual.from_h(manual.to_h).to_h
  end

  def test_authentication_models_validate_and_serialize
    api_key = UTCP::Auth.from_h(auth_type: "api_key", api_key: "secret", location: "query")
    basic = UTCP::Auth.from_h(auth_type: "basic", username: "u", password: "p")
    oauth = UTCP::Auth.from_h(
      auth_type: "oauth2", token_url: "https://example.com/token",
      client_id: "id", client_secret: "secret", scope: "read"
    )

    assert_instance_of UTCP::ApiKeyAuth, api_key
    assert_equal "query", api_key.to_h["location"]
    assert_instance_of UTCP::BasicAuth, basic
    assert_instance_of UTCP::OAuth2Auth, oauth
    assert_raises(UTCP::ValidationError) { UTCP::Auth.from_h(auth_type: "unknown") }
  end

  def test_allowed_protocols_default_to_own_type_for_nil_and_empty_array
    omitted = UTCP::TextCallTemplate.new(content: "{}")
    empty = UTCP::TextCallTemplate.new(content: "{}", allowed_communication_protocols: [])

    assert_equal ["text"], omitted.allowed_protocols
    assert_equal ["text"], empty.allowed_protocols
  end

  def test_invalid_models_raise_specific_validation_errors
    assert_raises(UTCP::ValidationError) { UTCP::CallTemplate.from_h({}) }
    assert_raises(UTCP::ValidationError) do
      UTCP::HttpCallTemplate.new(url: "https://example.com", http_method: "INVALID")
    end
    assert_raises(UTCP::ValidationError) do
      UTCP::Tool.new(name: "x", tool_call_template: { call_template_type: "missing" })
    end
  end

  def test_serializers_match_reference_style_api
    serializer = UTCP::ToolSerializer.new
    tool = serializer.validate_dict(
      name: "echo",
      tool_call_template: { call_template_type: "text", content: "ok" }
    )

    assert_equal "echo", serializer.to_dict(tool)["name"]
    assert_equal tool, serializer.copy(tool)
  end
end
