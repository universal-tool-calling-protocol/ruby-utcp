# frozen_string_literal: true

require "utcp"

# The server answers the framed discovery message {"type":"utcp"} with a manual.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "tcp_service",
    call_template_type: "tcp",
    host: ENV.fetch("UTCP_TCP_HOST", "localhost"),
    port: Integer(ENV.fetch("UTCP_TCP_PORT", "9000")),
    framing_strategy: "length_prefix",
    length_prefix_bytes: 4,
    length_prefix_endian: "big",
    request_data_format: "json",
    response_byte_format: "utf-8"
  }]
})

puts client.call_tool("tcp_service.echo", message: "Hello over TCP")
