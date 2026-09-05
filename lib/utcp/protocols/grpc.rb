# frozen_string_literal: true

module UTCP
  module ProtobufWire
    module_function

    def string_field(number, value)
      bytes = value.to_s.b
      varint((number << 3) | 2) + varint(bytes.bytesize) + bytes
    end

    def varint(value)
      number = Integer(value)
      result = +"".b
      loop do
        byte = number & 0x7F
        number >>= 7
        byte |= 0x80 unless number.zero?
        result << byte
        break if number.zero?
      end
      result
    end

    def fields(bytes)
      data = bytes.to_s.b
      offset = 0
      result = Hash.new { |hash, key| hash[key] = [] }
      while offset < data.bytesize
        tag, offset = read_varint(data, offset)
        number = tag >> 3
        wire = tag & 7
        case wire
        when 0
          value, offset = read_varint(data, offset)
        when 1
          value = data.byteslice(offset, 8)
          offset += 8
        when 2
          length, offset = read_varint(data, offset)
          raise SerializerValidationError, "truncated protobuf field" if offset + length > data.bytesize
          value = data.byteslice(offset, length)
          offset += length
        when 5
          value = data.byteslice(offset, 4)
          offset += 4
        else
          raise SerializerValidationError, "unsupported protobuf wire type #{wire}"
        end
        result[number] << value
      end
      result
    end

    def read_varint(data, offset)
      value = 0
      shift = 0
      loop do
        raise SerializerValidationError, "truncated protobuf varint" if offset >= data.bytesize
        byte = data.getbyte(offset)
        offset += 1
        value |= (byte & 0x7F) << shift
        return [value, offset] if (byte & 0x80).zero?
        shift += 7
        raise SerializerValidationError, "protobuf varint is too long" if shift > 63
      end
    end
  end

  class GRPCGemClient
    def initialize(template)
      require "grpc"
      address = "#{template.host}:#{template.port}"
      credentials = template.use_ssl ? GRPC::Core::ChannelCredentials.new : :this_channel_is_insecure
      @stub = GRPC::ClientStub.new(address, credentials)
    rescue LoadError => error
      raise MissingDependencyError,
            "gRPC requires the optional 'grpc' gem (add gem \"grpc\" to your Gemfile): #{error.message}"
    end

    def unary(route, payload, timeout:, metadata: {})
      @stub.request_response(
        route, payload,
        ->(value) { value.to_s.b }, ->(bytes) { bytes },
        deadline: Time.now + timeout,
        metadata: metadata
      )
    rescue GRPC::Unauthenticated, GRPC::PermissionDenied => error
      raise AuthenticationError, "gRPC authentication failed: #{error.details}"
    end

    def server_stream(route, payload, timeout:, metadata: {})
      return enum_for(__method__, route, payload, timeout: timeout, metadata: metadata) unless block_given?

      @stub.server_streamer(
        route, payload,
        ->(value) { value.to_s.b }, ->(bytes) { bytes },
        deadline: Time.now + timeout,
        metadata: metadata
      ).each { |response| yield response }
    rescue GRPC::Unauthenticated, GRPC::PermissionDenied => error
      raise AuthenticationError, "gRPC authentication failed: #{error.details}"
    end
  end

  class GRPCProtocol < HTTPProtocol
    def initialize(rpc_client_factory: nil, **options)
      super(**options)
      @rpc_client_factory = rpc_client_factory || ->(template) { GRPCGemClient.new(template) }
    end

    def register_manual(client, template)
      assert_grpc_template!(template)
      response = rpc_client(template).unary(
        route(template, "GetManual"), "".b,
        timeout: template.timeout,
        metadata: grpc_metadata(template)
      )
      fields = ProtobufWire.fields(response)
      tools = fields[2].map do |tool_bytes|
        tool_fields = ProtobufWire.fields(tool_bytes)
        {
          "name" => tool_fields[1].first.to_s.force_encoding(Encoding::UTF_8),
          "description" => tool_fields[2].first.to_s.force_encoding(Encoding::UTF_8),
          "tool_call_template" => template.to_h
        }
      end
      manual = Manual.new(
        utcp_version: VERSION,
        manual_version: fields[1].first.to_s.empty? ? "1.0.0" : fields[1].first.to_s,
        tools: tools
      )
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register gRPC manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_grpc_template!(template)
      response = rpc_client(template).unary(
        route(template, template.method_name || "CallTool"),
        tool_call_request(tool_name, tool_args),
        timeout: template.timeout,
        metadata: grpc_metadata(template)
      )
      decode_tool_response(response)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("gRPC tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      assert_grpc_template!(template)
      method = template.method_name || "CallToolStream"
      rpc_client(template).server_stream(
        route(template, method),
        tool_call_request(tool_name, tool_args),
        timeout: template.timeout,
        metadata: grpc_metadata(template)
      ).each { |response| yield decode_tool_response(response) }
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("streaming gRPC tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_grpc_template!(template)
      raise ValidationError, "gRPC protocol requires a GrpcCallTemplate" unless template.is_a?(GrpcCallTemplate)

      case template.auth
      when nil, BasicAuth, OAuth2Auth
        nil
      when ApiKeyAuth
        unless template.auth.location == "header"
          raise AuthenticationError, "gRPC API keys require location=header (request metadata)"
        end
        assert_header_safe!(template.auth.var_name, "API key name")
        assert_header_safe!(template.auth.api_key, "API key value")
      else
        raise AuthenticationError, "Unsupported gRPC authentication type: #{template.auth.auth_type}"
      end
    end

    def rpc_client(template)
      @rpc_client_factory.call(template)
    end

    def route(template, method)
      "/#{template.service_name}/#{method}"
    end

    def tool_call_request(tool_name, tool_args)
      ProtobufWire.string_field(1, tool_name) +
        ProtobufWire.string_field(2, JSON.generate(Utils.stringify_keys(tool_args || {})))
    end

    def decode_tool_response(bytes)
      json = ProtobufWire.fields(bytes)[1].first.to_s
      json.empty? ? nil : decode_json_or_text(json.force_encoding(Encoding::UTF_8))
    end

    def grpc_metadata(template)
      values = Utils.stringify_keys(template.metadata || {})
      values["target"] = template.target if template.target
      case template.auth
      when ApiKeyAuth
        values[template.auth.var_name.downcase] = template.auth.api_key
      when BasicAuth
        values["authorization"] = "Basic #{Base64.strict_encode64("#{template.auth.username}:#{template.auth.password}")}"
      when OAuth2Auth
        values["authorization"] = "Bearer #{oauth_token(template.auth)}"
      end
      values
    end
  end
  GrpcCommunicationProtocol = GRPCProtocol
  GRPCCommunicationProtocol = GRPCProtocol
end
