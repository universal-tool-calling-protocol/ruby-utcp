# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  class MemoryTemplate < UTCP::CallTemplate
    attr_reader :manual_data

    def initialize(manual_data:, call_template_type: "memory_test", **options)
      super(call_template_type: call_template_type, **options)
      @manual_data = manual_data
    end

    def to_h
      super.merge("manual_data" => manual_data)
    end
  end

  class MemoryProtocol < UTCP::CommunicationProtocol
    def register_manual(_client, template)
      UTCP::RegisterManualResult.new(
        manual_call_template: template,
        manual: UTCP::Manual.from_h(template.manual_data),
        success: true
      )
    end

    def deregister_manual(_client, _template); end

    def call_tool(_client, _name, arguments, _template)
      arguments
    end
  end

  def text_manual(tools)
    JSON.generate(
      manual_version: "1.0.0",
      utcp_version: "1.1.0",
      tools: tools
    )
  end

  def test_create_registers_and_qualifies_tools
    content = text_manual([
      {
        name: "hello",
        description: "Friendly greeting",
        tags: ["greeting"],
        tool_call_template: { call_template_type: "text", content: "hello" }
      }
    ])

    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "my-tools", call_template_type: "text", content: content }]
    })

    assert_equal ["my_tools.hello"], client.list_tools.map(&:name)
    assert_equal "hello", client.call_tool("my_tools.hello")
    assert client.registration_results.first.success?
  end

  def test_v1_1_filters_mixed_protocol_tools_by_default
    content = text_manual([
      {
        name: "dangerous",
        tool_call_template: {
          call_template_type: "cli",
          commands: [{ command: "printf should-not-run" }]
        }
      }
    ])
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "safe", call_template_type: "text", content: content }]
    })

    assert_empty client.list_tools
    assert_raises(UTCP::ToolNotFoundError) { client.call_tool("safe.dangerous") }
  end

  def test_explicit_allow_list_registers_and_calls_mixed_protocol_tool
    content = text_manual([
      {
        name: "echo",
        tool_call_template: {
          call_template_type: "cli",
          commands: [{ command: "printf %s UTCP_ARG_value_UTCP_END" }]
        }
      }
    ])
    client = UTCP::Client.create(config: {
      manual_call_templates: [{
        name: "mixed",
        call_template_type: "text",
        content: content,
        allowed_communication_protocols: %w[text cli]
      }]
    })

    value = "hello; printf PWNED"
    assert_equal value, client.call_tool("mixed.echo", value: value)
  end

  def test_call_rechecks_allowed_protocols
    client = UTCP::Client.new
    template = UTCP::TextCallTemplate.new(name: "safe", content: "{}")
    tool = UTCP::Tool.new(
      name: "safe.command",
      tool_call_template: {
        call_template_type: "cli",
        commands: [{ command: "printf no" }]
      }
    )
    client.config.tool_repository.save_manual(
      template,
      UTCP::Manual.new(tools: [tool])
    )

    assert_raises(UTCP::ProtocolNotAllowedError) { client.call_tool("safe.command") }
  end

  def test_duplicate_and_deregister
    content = text_manual([
      { name: "one", tool_call_template: { call_template_type: "text", content: "1" } }
    ])
    template = { name: "demo", call_template_type: "text", content: content }
    client = UTCP::Client.new

    assert client.register_manual(template).success?
    assert_raises(UTCP::ManualAlreadyRegisteredError) { client.register_manual(template) }
    assert client.deregister_manual("demo")
    refute client.deregister_manual("demo")
    assert_empty client.list_tools
  end

  def test_search_ranks_tags_and_filters_required_tags
    content = text_manual([
      {
        name: "weather",
        description: "Current forecast for a city",
        tags: %w[weather forecast],
        tool_call_template: { call_template_type: "text", content: "sunny" }
      },
      {
        name: "calendar",
        description: "List meetings",
        tags: ["calendar"],
        tool_call_template: { call_template_type: "text", content: "none" }
      }
    ])
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "demo", call_template_type: "text", content: content }]
    })

    assert_equal "demo.weather", client.search_tools("weather in Warsaw", limit: 1).first.name
    filtered = client.search_tools("list", any_of_tags_required: ["calendar"])
    assert_equal ["demo.calendar"], filtered.map(&:name)
  end

  def test_required_variables_for_registered_tool
    client = UTCP::Client.new
    template = UTCP::HttpCallTemplate.new(name: "api", url: "https://example.com/manual")
    tool = UTCP::Tool.new(
      name: "api.lookup",
      tool_call_template: {
        call_template_type: "http",
        url: "https://example.com/${VERSION}/lookup",
        auth: { auth_type: "api_key", api_key: "${TOKEN}" }
      }
    )
    client.config.tool_repository.save_manual(template, UTCP::Manual.new(tools: [tool]))

    assert_equal %w[api_TOKEN api_VERSION].sort,
                 client.get_required_variables_for_registered_tool("api.lookup").sort
  end

  def test_streaming_returns_an_enumerator
    content = text_manual([
      { name: "one", tool_call_template: { call_template_type: "text", content: "chunk" } }
    ])
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "demo", call_template_type: "text", content: content }]
    })

    assert_equal ["chunk"], client.call_tool_streaming("demo.one").to_a
  end

  def test_custom_call_template_and_protocol_plugins
    UTCP.register_call_template("memory_test", MemoryTemplate)
    UTCP.register_protocol("memory_test", MemoryProtocol.new)
    manual = {
      utcp_version: "1.1.0",
      tools: [{
        name: "echo",
        tool_call_template: { call_template_type: "memory_test", manual_data: {} }
      }]
    }
    client = UTCP::Client.create(config: {
      manual_call_templates: [{ name: "memory", call_template_type: "memory_test", manual_data: manual }]
    })

    assert_equal({ "value" => 3 }, client.call_tool("memory.echo", "value" => 3))
  end
end
