# frozen_string_literal: true

require "json"
require "utcp"

manual = {
  utcp_version: "1.1.0",
  manual_version: "1.0.0",
  tools: [{
    name: "motd",
    description: "Return a static message",
    tool_call_template: {
      call_template_type: "text",
      content: "Hello from a text UTCP tool"
    }
  }]
}

client = UTCP::Client.create(config: {
  manual_call_templates: [{ name: "static", call_template_type: "text", content: JSON.generate(manual) }]
})

puts client.call_tool("static.motd")
