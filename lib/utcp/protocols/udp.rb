# frozen_string_literal: true

module UTCP
  class UDPProtocol < CommunicationProtocol
    include SocketSupport

    def initialize(socket_factory: nil)
      @socket_factory = socket_factory || -> { UDPSocket.new }
    end

    def register_manual(client, template)
      assert_template!(template)
      response = exchange(template, JSON.generate("type" => "utcp"), response_count: 1)
      success(template, manual_from_payload(template, response, source: "UDP discovery response"))
    rescue StandardError => error
      client.logger.warn("Unable to register UDP manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_template!(template)
      exchange(template, format_socket_message(template, tool_args),
               response_count: template.number_of_response_datagrams)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("UDP tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_template!(template)
      raise ValidationError, "UDP protocol requires a UdpCallTemplate" unless template.is_a?(UdpCallTemplate)

      assert_no_auth!(template)
    end

    def exchange(template, message, response_count:)
      socket = @socket_factory.call
      socket.connect(template.host, template.port)
      socket.write(message.to_s.b)
      return nil if response_count.zero?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + socket_timeout_seconds(template)
      budget = ResponseByteBudget.new(template.max_response_bytes, "UDP")
      values = response_count.times.map do
        wait_readable!(socket, deadline, "UDP read")
        payload = socket.recv(65_535)
        budget.consume(payload)
        decode_socket_payload(payload, template.response_byte_format)
      end
      values.length == 1 ? values.first : values
    rescue Error
      raise
    rescue SocketError, IOError, SystemCallError => error
      raise ToolCallError, "UDP request failed: #{error.message}"
    ensure
      socket.close if socket && !socket.closed?
    end
  end
  UdpCommunicationProtocol = UDPProtocol
  UDPCommunicationProtocol = UDPProtocol
end
