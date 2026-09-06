# frozen_string_literal: true

require_relative "test_helper"

class OpenAPIConverterTest < Minitest::Test
  def document
    {
      "openapi" => "3.0.3", "info" => { "title" => "Tests", "version" => "1.0" },
      "servers" => [{ "url" => "https://example.test/api" }],
      "components" => {},
      "paths" => { "/items" => { "get" => { "operationId" => "items", "responses" => { "200" => { "description" => "OK" } } } } }
    }
  end

  def convert(spec, **options)
    UTCP::OpenAPIConverter.new(spec, **options).convert.tools.first
  end

  def test_parameter_references_and_operation_overrides
    spec = document
    spec["components"]["parameters"] = {
      "Tenant" => { "name" => "X-Tenant", "in" => "header", "required" => true, "schema" => { "type" => "string" } }
    }
    path = spec["paths"]["/items"]
    path["parameters"] = [{ "$ref" => "#/components/parameters/Tenant" }]
    tool = convert(spec)
    assert_equal ["X-Tenant"], tool.inputs["required"]
    assert_equal ["X-Tenant"], tool.tool_call_template.header_fields
    path["get"]["parameters"] = [{ "name" => "X-Tenant", "in" => "header", "schema" => { "type" => "integer" } }]
    tool = convert(spec)
    assert_nil tool.inputs["required"]
    assert_equal "integer", tool.inputs["properties"]["X-Tenant"]["type"]
    assert_equal ["X-Tenant"], tool.tool_call_template.header_fields
  end

  def test_relative_servers_and_server_precedence
    spec = document
    spec["servers"] = [{ "url" => "/v1" }]
    options = { spec_url: "https://example.test/docs/openapi.json" }
    assert_equal "https://example.test/v1/items", convert(spec, **options).tool_call_template.url
    spec["paths"]["/items"]["servers"] = [{ "url" => "../v2" }]
    assert_equal "https://example.test/v2/items", convert(spec, **options).tool_call_template.url
    spec["paths"]["/items"]["get"]["servers"] = [{ "url" => "./v3" }]
    assert_equal "https://example.test/docs/v3/items", convert(spec, **options).tool_call_template.url
    assert_equal "https://override.test/items", convert(spec, **options.merge(base_url: "https://override.test")).tool_call_template.url
    assert_raises(UTCP::ValidationError) { convert(spec) }
  end

  def test_request_body_response_and_nested_recursive_schema_references
    spec = document
    spec["components"] = {
      "schemas" => { "Node" => { "type" => "object", "properties" => {
        "name" => { "type" => "string" }, "child" => { "$ref" => "#/components/schemas/Node" }
      } } },
      "requestBodies" => { "NodeBody" => { "required" => true, "content" => {
        "application/json" => { "schema" => { "$ref" => "#/components/schemas/Node" } }
      } } },
      "responses" => { "Nodes" => { "description" => "OK", "content" => {
        "application/json" => { "schema" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/Node" } } }
      } } }
    }
    operation = spec["paths"]["/items"]["get"]
    operation["requestBody"] = { "$ref" => "#/components/requestBodies/NodeBody" }
    operation["responses"]["200"] = { "$ref" => "#/components/responses/Nodes" }
    original = Marshal.dump(spec)
    tool = convert(spec)
    assert_equal ["body"], tool.inputs["required"]
    [tool.inputs.to_h, tool.outputs.to_h].each do |schema|
      definition = schema.fetch("$defs").values.first
      assert_equal "string", definition.fetch("properties").fetch("name").fetch("type")
      reference = definition.fetch("properties").fetch("child").fetch("$ref")
      assert_equal definition, reference.delete_prefix("#/").split("/").reduce(schema) { |node, key| node.fetch(key) }
    end
    assert_equal original, Marshal.dump(spec)
  end

  def test_missing_external_and_circular_object_references_fail_explicitly
    ["#/components/parameters/Missing", "other.json#/Parameter"].each do |reference|
      spec = document
      spec["paths"]["/items"]["parameters"] = [{ "$ref" => reference }]
      assert_raises(UTCP::ValidationError) { convert(spec) }
    end
    spec = document
    spec["components"]["parameters"] = { "Loop" => { "$ref" => "#/components/parameters/Loop" } }
    spec["paths"]["/items"]["parameters"] = [{ "$ref" => "#/components/parameters/Loop" }]
    assert_raises(UTCP::ValidationError) { convert(spec) }
  end

  def test_swagger_references_and_escaped_json_pointer_tokens
    spec = document
    spec.delete("openapi")
    spec.delete("servers")
    spec.merge!("swagger" => "2.0", "host" => "example.test", "basePath" => "/v2", "schemes" => ["https"])
    spec["parameters"] = { "a/b~c" => { "name" => "q", "in" => "query", "type" => "string" } }
    spec["paths"]["/items"]["parameters"] = [{ "$ref" => "#/parameters/a~1b~0c" }]
    tool = convert(spec)
    assert_equal "https://example.test/v2/items", tool.tool_call_template.url
    assert_equal "string", tool.inputs["properties"]["q"]["type"]
  end

  def test_exported_schema_definitions_do_not_overwrite_existing_names
    spec = document
    spec["components"]["schemas"] = { "Value" => { "type" => "integer" } }
    spec["paths"]["/items"]["get"]["responses"]["200"]["content"] = {
      "application/json" => { "schema" => {
        "$defs" => { "utcp_ref_1" => { "type" => "string" } },
        "type" => "array", "items" => { "$ref" => "#/components/schemas/Value" }
      } }
    }
    output = convert(spec).outputs.to_h
    assert_equal "string", output["$defs"]["utcp_ref_1"]["type"]
    name = output["items"]["$ref"].split("/").last
    assert_equal "integer", output["$defs"][name]["type"]
  end
end
