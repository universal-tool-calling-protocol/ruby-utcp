# frozen_string_literal: true

require "json"
require "grpc"
require "utcp"

class RawProtobufMessage
  attr_reader :bytes

  def initialize(bytes = "".b)
    @bytes = bytes.to_s.b
  end

  def self.encode(message)
    message.bytes
  end

  def self.decode(bytes)
    new(bytes)
  end
end

class ExampleUTCPService
  include GRPC::GenericService
  self.marshal_class_method = :encode
  self.unmarshal_class_method = :decode
  self.service_name = "grpcpb.UTCPService"

  rpc :GetManual, RawProtobufMessage, RawProtobufMessage
  rpc :CallTool, RawProtobufMessage, RawProtobufMessage
  rpc :CallToolStream, RawProtobufMessage, stream(RawProtobufMessage)
end

class ExampleUTCPServer < ExampleUTCPService
  def get_manual(_request, _call)
    tool = UTCP::ProtobufWire.string_field(1, "echo") +
      UTCP::ProtobufWire.string_field(2, "Echo a JSON message")
    RawProtobufMessage.new(
      UTCP::ProtobufWire.string_field(1, "1.0.0") +
      UTCP::ProtobufWire.string_field(2, tool)
    )
  end

  def call_tool(request, _call)
    fields = UTCP::ProtobufWire.fields(request.bytes)
    args = JSON.parse(fields[2].first.to_s)
    result = JSON.generate(echo: args["message"])
    RawProtobufMessage.new(UTCP::ProtobufWire.string_field(1, result))
  end

  def call_tool_stream(request, call)
    response = call_tool(request, call)
    [response].each
  end
end

port = Integer(ENV.fetch("PORT", "50051"))
server = GRPC::RpcServer.new
server.add_http2_port("127.0.0.1:#{port}", :this_port_is_insecure)
server.handle(ExampleUTCPServer.new)
warn "Listening on grpc://127.0.0.1:#{port}"
server.run_till_terminated_or_interrupted(%w[INT TERM], 1)
