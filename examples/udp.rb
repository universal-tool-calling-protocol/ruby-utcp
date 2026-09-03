# frozen_string_literal: true

require "utcp"

# The server answers {"type":"utcp"} with one manual datagram.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "udp_service",
    call_template_type: "udp",
    host: ENV.fetch("UTCP_UDP_HOST", "localhost"),
    port: Integer(ENV.fetch("UTCP_UDP_PORT", "9001")),
    number_of_response_datagrams: 1,
    request_data_format: "json",
    response_byte_format: "utf-8"
  }]
})

puts client.call_tool("udp_service.echo", message: "Hello over UDP")
