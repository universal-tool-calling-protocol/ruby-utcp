# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "json"
require "socket"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
port = Integer(ENV.fetch("PORT", "8083"))
endpoint = "ws://localhost:#{port}/utcp"

def read_exact(socket, length)
  value = +"".b
  value << socket.readpartial(length - value.bytesize) while value.bytesize < length
  value
end

def read_frame(socket)
  first, second = read_exact(socket, 2).unpack("CC")
  opcode = first & 0x0F
  length = second & 0x7F
  length = read_exact(socket, 2).unpack1("n") if length == 126
  length = read_exact(socket, 8).unpack1("Q>") if length == 127
  mask = (second & 0x80).zero? ? nil : read_exact(socket, 4)
  payload = read_exact(socket, length)
  if mask
    payload = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
  end
  [opcode, payload]
end

def write_frame(socket, payload, opcode = 0x1)
  bytes = payload.to_s.b
  header = [0x80 | opcode].pack("C")
  header << if bytes.bytesize < 126
              [bytes.bytesize].pack("C")
            elsif bytes.bytesize <= 65_535
              [126, bytes.bytesize].pack("Cn")
            else
              [127, bytes.bytesize].pack("CQ>")
            end
  socket.write(header + bytes)
end

server = TCPServer.new("127.0.0.1", port)
warn "Listening on #{endpoint}"

loop do
  socket = server.accept
  Thread.new(socket) do |client|
    header = +""
    header << client.readpartial(1024) until header.include?("\r\n\r\n")
    headers = header.split("\r\n").drop(1).each_with_object({}) do |line, values|
      name, value = line.split(":", 2)
      values[name.downcase] = value.to_s.strip
    end
    accept = Base64.strict_encode64(Digest::SHA1.digest(headers.fetch("sec-websocket-key") + GUID))
    response = +"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n"
    response << "Sec-WebSocket-Protocol: #{headers["sec-websocket-protocol"]}\r\n" if headers["sec-websocket-protocol"]
    client.write(response + "\r\n")

    loop do
      opcode, bytes = read_frame(client)
      break if opcode == 0x8
      if opcode == 0x9
        write_frame(client, bytes, 0xA)
        next
      end
      message = JSON.parse(bytes)
      if message["type"] == "utcp"
        write_frame(client, JSON.generate(
          utcp_version: "1.1.0",
          tools: [{
            name: "echo",
            tool_call_template: {
              call_template_type: "websocket",
              url: endpoint,
              protocol: "utcp-v1",
              response_format: "json"
            }
          }]
        ))
      else
        write_frame(client, JSON.generate(echo: message["message"]))
      end
    end
  rescue EOFError, IOError, SystemCallError, JSON::ParserError
    nil
  ensure
    client.close unless client.closed?
  end
end
