# frozen_string_literal: true

require "utcp"
require "rbconfig"

# Works with stdio and Streamable HTTP MCP servers. Tools are named server.tool.
server = if ENV["MCP_URL"]
           { transport: "http", url: ENV.fetch("MCP_URL") }
         else
           {
             transport: "stdio",
             command: ENV.fetch("MCP_COMMAND", RbConfig.ruby),
             args: ENV["MCP_COMMAND"] ? [] : [File.expand_path("servers/mcp_stdio_server.rb", __dir__)]
           }
         end

client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "mcp_bridge",
    call_template_type: "mcp",
    config: { mcpServers: { demo: server } },
    register_resources_as_tools: true
  }]
})

puts client.list_tools.map(&:name)
puts client.call_tool("mcp_bridge.demo.echo", message: "Hello from MCP").inspect
client.close
