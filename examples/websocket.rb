# frozen_string_literal: true

require "utcp"

# The server first answers {"type":"utcp"} with a manual, then handles tool messages.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "realtime",
    call_template_type: "websocket",
    url: ENV.fetch("UTCP_WEBSOCKET_URL", "ws://localhost:8083/utcp"),
    protocol: "utcp-v1",
    keep_alive: true,
    response_format: "json"
  }]
})

puts client.call_tool("realtime.echo", message: "Hello over WebSocket").inspect
