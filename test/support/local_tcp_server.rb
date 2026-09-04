# frozen_string_literal: true

require "socket"
require "timeout"

module LocalTCPServer
  def with_tcp_server(handler)
    server = TCPServer.new("127.0.0.1", 0)
    worker = Thread.new do
      socket = server.accept
      handler.call(socket)
    ensure
      socket.close if socket && !socket.closed?
    end
    worker.report_on_exception = false
    Timeout.timeout(5) { yield server.addr[1] }
  ensure
    server.close if server && !server.closed?
    if worker
      completed = worker.join(1)
      worker.kill.join unless completed
      worker.value if completed && !$!
    end
  end

  def read_http_request(socket)
    lines = []
    while (line = socket.gets) && line != "\r\n"
      lines << line
    end
    lines.join
  end

  def accept_websocket(socket, response_headers: {})
    request = read_http_request(socket)
    key = request[/^Sec-WebSocket-Key:\s*(.+)\r$/i, 1]
    accept = Base64.strict_encode64(Digest::SHA1.digest(key + UTCP::WebSocketConnection::GUID))
    headers = { "Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Accept" => accept }.merge(response_headers)
    socket.write("HTTP/1.1 101 Switching Protocols\r\n" + headers.map { |name, value| "#{name}: #{value}\r\n" }.join + "\r\n")
    request
  end

  def websocket_frame(payload, opcode: 1, final: true)
    payload = payload.b
    header = [opcode | (final ? 0x80 : 0)].pack("C")
    header << if payload.bytesize < 126
                [payload.bytesize].pack("C")
              elsif payload.bytesize <= 65_535
                [126, payload.bytesize].pack("Cn")
              else
                [127, payload.bytesize].pack("CQ>")
              end
    header + payload
  end

  def read_websocket_frame(socket)
    first, second = socket.read(2).unpack("CC")
    length = second & 127
    length = socket.read(2).unpack1("n") if length == 126
    length = socket.read(8).unpack1("Q>") if length == 127
    mask = (second & 128).zero? ? nil : socket.read(4)
    payload = socket.read(length)
    payload = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*") if mask
    [first & 15, payload]
  end
end
