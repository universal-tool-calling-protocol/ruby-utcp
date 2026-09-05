# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "openssl"
require "socket"
require "uri"

module UTCP
  module WebSocketURLSecurity
    module_function

    def validate!(url)
      uri = URI.parse(url.to_s)
      raise SecurityError, "WebSocket URL must use ws or wss" unless %w[ws wss].include?(uri.scheme)
      raise SecurityError, "WebSocket URL must contain a host" if uri.host.nil? || uri.host.empty?
      raise SecurityError, "WebSocket URL must not contain user information" if uri.userinfo
      if uri.scheme == "ws" && !URLSecurity.loopback_host?(uri.host)
        raise SecurityError, "plain WebSocket is allowed only for loopback hosts"
      end
      uri
    rescue URI::InvalidURIError => error
      raise SecurityError, "Invalid WebSocket URL: #{error.message}"
    end
  end

  class WebSocketConnection
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    MAX_HEADER_SIZE = 65_536
    MAX_MESSAGE_SIZE = 16 * 1024 * 1024

    def initialize(url, headers = {}, protocol = nil, timeout = 30)
      @uri = WebSocketURLSecurity.validate!(url)
      @timeout = Float(timeout)
      @read_buffer = +"".b
      @closed = false
      open_socket
      handshake(headers, protocol)
    rescue StandardError
      @socket.close if @socket && !@socket.closed?
      raise
    end

    def closed?
      @closed || @socket.closed?
    end

    def send_text(value)
      send_frame(0x1, value.to_s.encode(Encoding::UTF_8))
    end

    def send_binary(value)
      send_frame(0x2, value.to_s.b)
    end

    def read_message
      message = +"".b
      message_opcode = nil
      loop do
        fin, opcode, payload = read_frame
        case opcode
        when 0x0
          raise ToolCallError, "unexpected WebSocket continuation frame" unless message_opcode
          message << payload
        when 0x1, 0x2
          raise ToolCallError, "interleaved WebSocket data frame" if message_opcode
          message_opcode = opcode
          message << payload
        when 0x8
          send_frame(0x8, payload) unless @closed
          @closed = true
          return nil
        when 0x9
          send_frame(0xA, payload)
          next
        when 0xA
          next
        else
          raise ToolCallError, "unsupported WebSocket opcode #{opcode}"
        end
        raise ToolCallError, "WebSocket message exceeds #{MAX_MESSAGE_SIZE} bytes" if message.bytesize > MAX_MESSAGE_SIZE
        return [message_opcode, message] if fin
      end
    end

    def close
      send_frame(0x8, [1000].pack("n")) unless closed?
    rescue IOError, SystemCallError
      nil
    ensure
      @closed = true
      @socket.close if @socket && !@socket.closed?
    end

    private

    def open_socket
      tcp = Socket.tcp(@uri.host, websocket_port, connect_timeout: @timeout)
      if @uri.scheme == "wss"
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = @uri.host if ssl.respond_to?(:hostname=)
        ssl.sync_close = true
        ssl.connect
        @socket = ssl
      else
        @socket = tcp
      end
    rescue StandardError
      tcp.close if tcp && !tcp.closed?
      raise
    end

    def handshake(headers, protocol)
      key = Base64.strict_encode64(Random.new.bytes(16))
      path = websocket_request_target
      host = @uri.host.include?(":") ? "[#{@uri.host}]" : @uri.host
      default_port = @uri.scheme == "wss" ? 443 : 80
      host = "#{host}:#{websocket_port}" unless websocket_port == default_port
      values = {
        "Host" => host,
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Key" => key,
        "Sec-WebSocket-Version" => "13"
      }
      values["Sec-WebSocket-Protocol"] = protocol if protocol
      reserved = %w[host upgrade connection sec-websocket-key sec-websocket-version sec-websocket-protocol]
      Utils.stringify_keys(headers || {}).each do |name, value|
        raise SecurityError, "WebSocket header #{name.inspect} is reserved" if reserved.include?(name.downcase)

        values[name] = value.to_s
      end
      values.each do |name, value|
        raise SecurityError, "WebSocket header contains CR/LF" if name.to_s.match?(/[\r\n]/) || value.match?(/[\r\n]/)
      end
      request = "GET #{path} HTTP/1.1\r\n" + values.map { |name, value| "#{name}: #{value}\r\n" }.join + "\r\n"
      @socket.write(request)
      header_text = read_headers
      lines = header_text.split("\r\n")
      status = lines.shift.to_s.split[1].to_i
      if status == 401 || status == 403
        raise AuthenticationError, "WebSocket authentication failed with status #{status}"
      end
      raise ToolCallError, "WebSocket handshake failed with status #{status}" unless status == 101

      response_headers = lines.each_with_object({}) do |line, result|
        name, value = line.split(":", 2)
        result[name.to_s.downcase] = value.to_s.strip
      end
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      unless secure_compare(response_headers["sec-websocket-accept"].to_s, expected)
        raise SecurityError, "WebSocket handshake returned an invalid Sec-WebSocket-Accept"
      end
      unless response_headers["upgrade"].to_s.casecmp?("websocket") &&
             response_headers["connection"].to_s.downcase.split(/\s*,\s*/).include?("upgrade")
        raise ToolCallError, "WebSocket handshake did not confirm the protocol upgrade"
      end
      if protocol && response_headers["sec-websocket-protocol"] != protocol
        raise ToolCallError, "WebSocket server did not select the requested subprotocol"
      end
    end

    def websocket_port
      @uri.port || (@uri.scheme == "wss" ? 443 : 80)
    end

    def websocket_request_target
      path = @uri.path.to_s
      path = "/" if path.empty?
      @uri.query ? "#{path}?#{@uri.query}" : path
    end

    def read_headers
      until (index = @read_buffer.index("\r\n\r\n"))
        raise ToolCallError, "WebSocket handshake headers are too large" if @read_buffer.bytesize >= MAX_HEADER_SIZE
        wait_readable
        @read_buffer << @socket.readpartial(4096)
      end
      @read_buffer.slice!(0, index + 4).byteslice(0, index)
    end

    def send_frame(opcode, payload)
      raise IOError, "WebSocket is closed" if closed?

      bytes = payload.to_s.b
      mask = Random.new.bytes(4)
      header = [0x80 | opcode].pack("C")
      header << if bytes.bytesize < 126
                  [0x80 | bytes.bytesize].pack("C")
                elsif bytes.bytesize <= 65_535
                  [0x80 | 126, bytes.bytesize].pack("Cn")
                else
                  [0x80 | 127, bytes.bytesize].pack("CQ>")
                end
      masked = bytes.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      @socket.write(header + mask + masked)
    end

    def read_frame
      head = read_exact(2)
      first, second = head.unpack("CC")
      fin = (first & 0x80) != 0
      opcode = first & 0x0F
      masked = (second & 0x80) != 0
      length = second & 0x7F
      length = read_exact(2).unpack1("n") if length == 126
      length = read_exact(8).unpack1("Q>") if length == 127
      raise ToolCallError, "WebSocket frame exceeds #{MAX_MESSAGE_SIZE} bytes" if length > MAX_MESSAGE_SIZE

      mask = masked ? read_exact(4) : nil
      payload = read_exact(length)
      if mask
        payload = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      end
      [fin, opcode, payload]
    end

    def read_exact(length)
      while @read_buffer.bytesize < length
        wait_readable
        @read_buffer << @socket.readpartial([4096, length - @read_buffer.bytesize].max)
      end
      @read_buffer.slice!(0, length)
    rescue EOFError
      @closed = true
      raise ToolCallError, "WebSocket connection closed unexpectedly"
    end

    def wait_readable
      raise TimeoutError, "WebSocket read timed out" unless IO.select([@socket], nil, nil, @timeout)
    end

    def secure_compare(first, second)
      return false unless first.bytesize == second.bytesize

      first.bytes.zip(second.bytes).reduce(0) { |memo, pair| memo | (pair[0] ^ pair[1]) }.zero?
    end
  end

  class WebSocketProtocol < HTTPProtocol
    ConnectionEntry = Struct.new(:connection, :mutex)

    def initialize(connection_factory: nil, **options)
      super(**options)
      @connection_factory = connection_factory || lambda do |url, headers, protocol, timeout|
        WebSocketConnection.new(url, headers, protocol, timeout)
      end
      @connections = {}
      @connections_mutex = Mutex.new
    end

    def register_manual(client, template)
      assert_websocket_template!(template)
      entry, transient = connection_for(client, template, {})
      payload = entry.mutex.synchronize do
        entry.connection.send_text(JSON.generate("type" => "utcp"))
        _opcode, bytes = entry.connection.read_message
        bytes
      end
      success(template, manual_from_payload(template, payload, source: "WebSocket discovery response"))
    rescue StandardError => error
      client.logger.warn("Unable to register WebSocket manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    ensure
      entry.connection.close if entry && transient
    end

    def deregister_manual(client, template)
      entries = @connections_mutex.synchronize do
        keys = @connections.keys.select do |owner, url, subprotocol, _key|
          owner.equal?(client) && url == template.url && subprotocol == template.protocol
        end
        keys.map { |key| @connections.delete(key) }
      end
      entries.each { |entry| entry.connection.close }
      nil
    end

    def call_tool(client, tool_name, tool_args, template)
      assert_websocket_template!(template)
      args = Utils.stringify_keys(tool_args || {})
      entry, transient, message_args = connection_for(client, template, args, include_arguments: true)
      result = entry.mutex.synchronize do
        message = format_message(template, message_args)
        entry.connection.send_text(message)
        frame = entry.connection.read_message
        raise ToolCallError, "WebSocket closed without a response" unless frame

        decode_message(frame[1], template.response_format, frame[0])
      end
      result
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("WebSocket tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    ensure
      entry.connection.close if defined?(entry) && entry && defined?(transient) && transient
    end

    private

    def assert_websocket_template!(template)
      return if template.is_a?(WebSocketCallTemplate)

      raise ValidationError, "WebSocket protocol requires a WebSocketCallTemplate"
    end

    def connection_for(client, template, arguments, include_arguments: false)
      args = arguments.dup
      headers = Utils.stringify_keys(template.headers || {})
      template.header_fields.each { |field| headers[field] = args.delete(field).to_s if args.key?(field) }
      query = {}
      cookies = {}
      apply_auth(template.auth, headers, query, cookies)
      if template.auth.is_a?(OAuth2Auth)
        headers["Authorization"] = "Bearer #{oauth_token(template.auth)}"
      end
      headers["Cookie"] = cookies.map { |key, value| "#{key}=#{value}" }.join("; ") unless cookies.empty?
      url = append_query(template.url, query)
      WebSocketURLSecurity.validate!(url)
      key = [client, template.url, template.protocol, connection_key(template, url, headers)]
      if template.keep_alive
        entry = @connections_mutex.synchronize do
          current = @connections[key]
          if current.nil? || current.connection.closed?
            current = ConnectionEntry.new(@connection_factory.call(url, headers, template.protocol, template.timeout), Mutex.new)
            @connections[key] = current
          end
          current
        end
        include_arguments ? [entry, false, args] : [entry, false]
      else
        entry = ConnectionEntry.new(@connection_factory.call(url, headers, template.protocol, template.timeout), Mutex.new)
        include_arguments ? [entry, true, args] : [entry, true]
      end
    end

    def connection_key(template, url = template.url, headers = template.headers)
      [url, template.protocol, JSON.generate(Utils.stringify_keys(headers || {}).sort)].join("\0")
    end

    def format_message(template, arguments)
      value = template.message.nil? ? arguments : substitute_message_template(template.message, arguments)
      value.is_a?(String) ? value : JSON.generate(value)
    end

    def decode_message(bytes, response_format, opcode)
      return bytes.b if response_format == "raw" || opcode == 0x2

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      response_format == "text" ? text : decode_json_or_text(text)
    end
  end
  WebsocketCommunicationProtocol = WebSocketProtocol
  WebSocketCommunicationProtocol = WebSocketProtocol
end
