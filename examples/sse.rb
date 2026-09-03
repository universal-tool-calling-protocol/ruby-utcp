# frozen_string_literal: true

require "utcp"

# The discovery URL returns JSON; the discovered tool template points to an SSE endpoint.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "events",
    call_template_type: "sse",
    url: ENV.fetch("UTCP_SSE_MANUAL", "http://localhost:8081/utcp")
  }]
})

client.call_tool_streaming("events.watch", topic: "builds") do |event|
  puts "event: #{event.inspect}"
end
