# frozen_string_literal: true

require "json"
require "socket"

port = Integer(ENV.fetch("PORT", "9001"))
socket = UDPSocket.new
socket.bind("127.0.0.1", port)
warn "Listening on udp://127.0.0.1:#{port}"

manual = {
  utcp_version: "1.1.0",
  tools: [{
    name: "echo",
    tool_call_template: {
      call_template_type: "udp",
      host: "localhost",
      port: port,
      number_of_response_datagrams: 1,
      request_data_format: "json",
      response_byte_format: "utf-8"
    }
  }]
}

loop do
  bytes, sender = socket.recvfrom(65_535)
  request = JSON.parse(bytes)
  response = request["type"] == "utcp" ? JSON.generate(manual) : "Hello over UDP: #{request["message"]}"
  socket.send(response, 0, sender[3], sender[1])
rescue JSON::ParserError => error
  warn error.message
end
