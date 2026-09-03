# frozen_string_literal: true

require "json"
require "socket"

port = Integer(ENV.fetch("PORT", "9000"))

def read_exact(socket, length)
  value = +"".b
  value << socket.readpartial(length - value.bytesize) while value.bytesize < length
  value
end

def read_message(socket)
  length = read_exact(socket, 4).unpack1("N")
  read_exact(socket, length)
end

def write_message(socket, value)
  bytes = value.to_s.b
  socket.write([bytes.bytesize].pack("N") + bytes)
end

manual = {
  utcp_version: "1.1.0",
  tools: [{
    name: "echo",
    tool_call_template: {
      call_template_type: "tcp",
      host: "localhost",
      port: port,
      framing_strategy: "length_prefix",
      length_prefix_bytes: 4,
      length_prefix_endian: "big",
      request_data_format: "json",
      response_byte_format: "utf-8"
    }
  }]
}

server = TCPServer.new("127.0.0.1", port)
warn "Listening on tcp://127.0.0.1:#{port}"
loop do
  socket = server.accept
  Thread.new(socket) do |client|
    request = JSON.parse(read_message(client))
    response = if request["type"] == "utcp"
                 JSON.generate(manual)
               else
                 "Hello over TCP: #{request["message"]}"
               end
    write_message(client, response)
  rescue EOFError, IOError, SystemCallError, JSON::ParserError
    nil
  ensure
    client.close unless client.closed?
  end
end
