# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "utcp"

manual = {
  manual_version: "1.0.0",
  utcp_version: "1.1.0",
  tools: [
    {
      name: "greeting",
      description: "Return a greeting",
      inputs: { type: "object" },
      tool_call_template: {
        call_template_type: "text",
        content: "Hello from UTCP"
      }
    }
  ]
}

client = UTCP::Client.create(config: {
  manual_call_templates: [
    {
      name: "demo",
      call_template_type: "text",
      content: JSON.generate(manual)
    }
  ]
})

puts client.call_tool("demo.greeting")

