# frozen_string_literal: true

module UTCP
  class TCPProtocol < CommunicationProtocol
    include SocketSupport

    def initialize(socket_factory: nil)
      @socket_factory = socket_factory || lambda do |host, port, timeout|
        Socket.tcp(host, port, connect_timeout: timeout)
      end
    end

    def register_manual(client, template)
      assert_template!(template)
      response = exchange(template, JSON.generate("type" => "utcp"))
      success(template, manual_from_payload(template, response, source: "TCP discovery response"))
    rescue StandardError => error
      client.logger.warn("Unable to register TCP manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_template!(template)
      exchange(template, format_socket_message(template, tool_args))
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("TCP tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_template!(template)
      raise ValidationError, "TCP protocol requires a TcpCallTemplate" unless template.is_a?(TcpCallTemplate)

      assert_no_auth!(template)
    end

    def exchange(template, message)
      timeout = socket_timeout_seconds(template)
      socket = @socket_factory.call(template.host, template.port, timeout)
      socket.write(frame_message(message.to_s.b, template))
      payload = read_framed(socket, template, timeout)
      decode_socket_payload(payload, template.response_byte_format)
    rescue Timeout::Error, Errno::ETIMEDOUT => error
      raise TimeoutError, "TCP request timed out: #{error.message}"
    rescue Error
      raise
    rescue SocketError, IOError, SystemCallError => error
      raise ToolCallError, "TCP request failed: #{error.message}"
    ensure
      socket.close if socket && !socket.closed?
    end

    def frame_message(message, template)
      case template.framing_strategy
      when "length_prefix"
        pack = {
          [1, "big"] => "C", [1, "little"] => "C",
          [2, "big"] => "n", [2, "little"] => "v",
          [4, "big"] => "N", [4, "little"] => "V",
          [8, "big"] => "Q>", [8, "little"] => "Q<"
        }.fetch([template.length_prefix_bytes, template.length_prefix_endian])
        [message.bytesize].pack(pack) + message
      when "delimiter"
        message + escaped_delimiter(template.message_delimiter, template.interpret_escape_sequences)
      else
        message
      end
    end

    def read_framed(socket, template, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      maximum = [template.max_response_size, template.max_response_bytes].min
      case template.framing_strategy
      when "length_prefix"
        prefix = read_exact(socket, template.length_prefix_bytes, deadline)
        unpack = {
          [1, "big"] => "C", [1, "little"] => "C",
          [2, "big"] => "n", [2, "little"] => "v",
          [4, "big"] => "N", [4, "little"] => "V",
          [8, "big"] => "Q>", [8, "little"] => "Q<"
        }.fetch([template.length_prefix_bytes, template.length_prefix_endian])
        length = prefix.unpack1(unpack)
        raise ToolCallError, "TCP response exceeds max_response_bytes or max_response_size" if length > maximum

        read_exact(socket, length, deadline)
      when "delimiter"
        read_until(socket, escaped_delimiter(template.message_delimiter, template.interpret_escape_sequences),
                   maximum, deadline)
      when "fixed_length"
        if template.fixed_message_length > maximum
          raise ToolCallError, "TCP response exceeds max_response_bytes or max_response_size"
        end
        read_exact(socket, template.fixed_message_length, deadline)
      when "stream"
        read_stream(socket, maximum, deadline)
      end
    end

    def read_exact(socket, length, deadline)
      result = +"".b
      while result.bytesize < length
        wait_readable!(socket, deadline, "TCP read")
        chunk = socket.readpartial(length - result.bytesize)
        raise ToolCallError, "TCP connection closed before the complete response" if chunk.nil? || chunk.empty?

        result << chunk
      end
      result
    rescue EOFError
      raise ToolCallError, "TCP connection closed before the complete response"
    end

    def read_until(socket, delimiter, maximum, deadline)
      raise ValidationError, "message_delimiter cannot be empty" if delimiter.empty?

      result = +"".b
      loop do
        if (index = result.index(delimiter))
          raise ToolCallError, "TCP response exceeds max_response_bytes or max_response_size" if index > maximum
          return result.byteslice(0, index)
        end
        if result.bytesize >= maximum + delimiter.bytesize
          raise ToolCallError, "TCP response exceeds max_response_bytes or max_response_size"
        end

        wait_readable!(socket, deadline, "TCP read")
        result << socket.readpartial([4096, maximum + delimiter.bytesize - result.bytesize].min)
      end
    rescue EOFError
      raise ToolCallError, "TCP connection closed before the message delimiter"
    end

    def read_stream(socket, maximum, deadline)
      result = +"".b
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive? && IO.select([socket], nil, nil, remaining)

        begin
          result << socket.readpartial([4096, maximum + 1 - result.bytesize].min)
          if result.bytesize > maximum
            raise ToolCallError, "TCP response exceeds max_response_bytes or max_response_size"
          end
        rescue EOFError
          break
        end
      end
      result
    end
  end
  TcpCommunicationProtocol = TCPProtocol
  TCPCommunicationProtocol = TCPProtocol
end
