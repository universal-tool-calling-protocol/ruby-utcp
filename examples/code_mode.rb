# frozen_string_literal: true

require "json"
require "utcp"

# Reuses examples/servers/http_server.rb so Code Mode can focus on orchestration.
client = UTCP::CodeModeUtcpClient.create(config: {
  manual_call_templates: [{
    name: "rest",
    call_template_type: "http",
    url: ENV.fetch("UTCP_HTTP_MANUAL", "http://localhost:8080/utcp"),
    http_method: "GET"
  }]
})

execution = client.call_tool_chain(<<~'RUBY', timeout: 10)
  matches = codemode.search_tools("echo", limit: 1)
  tool_name = matches.first["name"]

  first = codemode.call_tool(tool_name, body: { message: "Hello from Code Mode" })
  second = codemode.call_tool(tool_name, body: { message: first["message"].upcase })

  messages = [first, second].map { |response| response["message"] }
  puts "Called #{tool_name} #{messages.length} times"

  { tool: tool_name, messages: messages }
RUBY

puts JSON.pretty_generate(execution)
