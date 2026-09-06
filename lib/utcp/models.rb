# frozen_string_literal: true

require "securerandom"
require_relative "version"
require_relative "errors"
require_relative "utils"
require_relative "response_limits"

module UTCP
  class JsonSchema
    include ModelSerialization
    COMMON_FIELDS = %w[
      $schema $id title description type properties items required enum const default
      examples format additionalProperties pattern minimum maximum minLength maxLength
    ].freeze

    def self.from_h(value)
      return value if value.is_a?(self)

      new(Utils.hash!(value || {}, "JSON Schema"))
    end

    def initialize(value = nil, **keywords)
      source = value || keywords
      @data = Utils.stringify_keys(Utils.hash!(source, "JSON Schema"))
    end

    def [](key)
      @data[schema_key(key)]
    end

    def []=(key, value)
      @data[schema_key(key)] = value
    end

    def to_h
      Utils.deep_copy(@data)
    end

    def method_missing(name, *arguments)
      key = name.to_s
      return @data[schema_key(key)] if arguments.empty? && schema_field?(key)
      return @data[schema_key(key[0..-2])] = arguments.first if key.end_with?("=") && arguments.length == 1

      super
    end

    def respond_to_missing?(name, include_private = false)
      key = name.to_s.sub(/=$/, "")
      schema_field?(key) || super
    end

    private

    def schema_key(key)
      { "schema_" => "$schema", "id_" => "$id" }.fetch(key.to_s, key.to_s)
    end

    def schema_field?(key)
      actual = schema_key(key)
      @data.key?(actual) || COMMON_FIELDS.include?(actual)
    end
  end
  JSONSchema = JsonSchema

  class Auth
    include ModelSerialization
    attr_accessor :auth_type

    def self.from_h(value)
      return value if value.is_a?(Auth)

      data = Utils.stringify_keys(Utils.hash!(value, "auth"))
      type = Utils.required_string!(data["auth_type"], "auth.auth_type")
      klass = UTCP.auth_class(type)
      raise ValidationError.new("unsupported authentication type #{type.inspect}", path: "auth.auth_type") unless klass

      klass.new(**Utils.symbolize_keys(data))
    rescue ValidationError
      raise
    rescue StandardError => error
      raise SerializerValidationError, "Invalid auth: #{error.message}"
    end

    def initialize(auth_type:, **extra)
      @auth_type = Utils.required_string!(auth_type, "auth_type")
      @extra = Utils.stringify_keys(extra)
    end

    def to_h
      { "auth_type" => auth_type }.merge(Utils.deep_copy(@extra))
    end

    def [](key)
      @extra[key.to_s]
    end
  end

  class ApiKeyAuth < Auth
    LOCATIONS = %w[header query cookie].freeze
    attr_accessor :api_key, :var_name, :location

    def initialize(api_key:, auth_type: "api_key", var_name: "X-Api-Key", location: "header", **extra)
      super(auth_type: auth_type, **extra)
      @api_key = Utils.required_string!(api_key, "api_key")
      @var_name = Utils.required_string!(var_name, "var_name")
      @location = location.to_s
      raise ValidationError.new("must be header, query, or cookie", path: "location") unless LOCATIONS.include?(@location)
    end

    def to_h
      super.merge("api_key" => api_key, "var_name" => var_name, "location" => location)
    end
  end

  class BasicAuth < Auth
    attr_accessor :username, :password

    def initialize(username:, password:, auth_type: "basic", **extra)
      super(auth_type: auth_type, **extra)
      @username = Utils.required_string!(username, "username")
      @password = Utils.required_string!(password, "password")
    end

    def to_h
      super.merge("username" => username, "password" => password)
    end
  end

  class OAuth2Auth < Auth
    attr_accessor :token_url, :client_id, :client_secret, :scope

    def initialize(token_url:, client_id:, client_secret:, auth_type: "oauth2", scope: nil, **extra)
      super(auth_type: auth_type, **extra)
      @token_url = Utils.required_string!(token_url, "token_url")
      @client_id = Utils.required_string!(client_id, "client_id")
      @client_secret = Utils.required_string!(client_secret, "client_secret")
      @scope = Utils.optional_string!(scope, "scope")
    end

    def to_h
      Utils.compact_hash(super.merge(
        "token_url" => token_url,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "scope" => scope
      ))
    end
  end

  class CallTemplate
    include ModelSerialization
    attr_accessor :name, :call_template_type, :auth, :allowed_communication_protocols

    def self.from_h(value)
      return value if value.is_a?(CallTemplate)

      data = Utils.stringify_keys(Utils.hash!(value, "call template"))
      type = Utils.required_string!(data["call_template_type"], "call_template_type")
      klass = UTCP.call_template_class(type)
      raise ValidationError.new("unsupported call template type #{type.inspect}", path: "call_template_type") unless klass

      klass.new(**Utils.symbolize_keys(data))
    rescue ValidationError
      raise
    rescue StandardError => error
      raise SerializerValidationError, "Invalid call template: #{error.message}"
    end

    def initialize(call_template_type:, name: nil, auth: nil, allowed_communication_protocols: nil, **extra)
      @name = name.nil? || name.to_s.empty? ? SecureRandom.hex(16) : name.to_s
      @call_template_type = Utils.required_string!(call_template_type.to_s, "call_template_type")
      @auth = auth.nil? ? nil : Auth.from_h(auth)
      @allowed_communication_protocols = normalize_protocols(allowed_communication_protocols)
      @extra = Utils.stringify_keys(extra)
    end

    def allowed_protocols
      protocols = allowed_communication_protocols
      protocols.nil? || protocols.empty? ? [call_template_type] : protocols.dup
    end

    def to_h
      Utils.compact_hash({
        "name" => name,
        "call_template_type" => call_template_type,
        "auth" => auth&.to_h,
        "allowed_communication_protocols" => allowed_communication_protocols&.dup
      }.merge(Utils.deep_copy(@extra)))
    end

    def [](key)
      @extra[key.to_s]
    end

    def method_missing(name, *arguments)
      key = name.to_s
      return @extra[key] if arguments.empty? && @extra.key?(key)
      return @extra[key[0..-2]] = arguments.first if key.end_with?("=") && arguments.length == 1

      super
    end

    def respond_to_missing?(name, include_private = false)
      @extra.key?(name.to_s.sub(/=$/, "")) || super
    end

    private

    def normalize_protocols(value)
      return nil if value.nil?

      protocols = Utils.array!(value, "allowed_communication_protocols").map(&:to_s)
      if protocols.any?(&:empty?)
        raise ValidationError.new("must contain non-empty protocol names", path: "allowed_communication_protocols")
      end
      protocols.uniq
    end
  end

  class HttpCallTemplate < CallTemplate
    include HTTPResponseLimits
    METHODS = %w[GET POST PUT DELETE PATCH HEAD OPTIONS].freeze
    attr_accessor :http_method, :url, :content_type, :auth_tools, :headers, :body_field,
                  :header_fields, :timeout

    def initialize(url:, call_template_type: "http", http_method: "GET", content_type: "application/json",
                   auth_tools: nil, headers: nil, body_field: "body", header_fields: nil,
                   timeout: nil, **common)
      super(call_template_type: call_template_type, **common)
      @url = Utils.required_string!(url, "url")
      @http_method = http_method.to_s.upcase
      raise ValidationError.new("unsupported HTTP method #{@http_method}", path: "http_method") unless METHODS.include?(@http_method)

      @content_type = Utils.required_string!(content_type, "content_type")
      @auth_tools = auth_tools.nil? ? nil : Auth.from_h(auth_tools)
      @headers = headers.nil? ? {} : Utils.stringify_keys(Utils.hash!(headers, "headers"))
      @body_field = body_field.nil? ? nil : body_field.to_s
      @header_fields = header_fields.nil? ? [] : Utils.array!(header_fields, "header_fields").map(&:to_s)
      @timeout = timeout.nil? ? nil : Float(timeout)
      if @timeout && (!@timeout.finite? || !@timeout.positive?)
        raise ValidationError.new("must be finite and greater than zero", path: "timeout")
      end
    end

    def to_h
      Utils.compact_hash(super.merge(
        "http_method" => http_method,
        "url" => url,
        "content_type" => content_type,
        "auth_tools" => auth_tools&.to_h,
        "headers" => headers.empty? ? nil : Utils.deep_copy(headers),
        "body_field" => body_field,
        "header_fields" => header_fields.empty? ? nil : header_fields.dup,
        "timeout" => timeout
      ))
    end
  end

  class SseCallTemplate < CallTemplate
    include HTTPResponseLimits
    attr_accessor :url, :event_type, :reconnect, :retry_timeout, :headers, :body_field,
                  :header_fields, :timeout

    def initialize(url:, call_template_type: "sse", event_type: nil, reconnect: true,
                   retry_timeout: 30_000, headers: nil, body_field: nil,
                   header_fields: nil, timeout: nil, **common)
      super(call_template_type: call_template_type, **common)
      @url = Utils.required_string!(url, "url")
      @event_type = Utils.optional_string!(event_type, "event_type")
      @reconnect = !!reconnect
      @retry_timeout = Integer(retry_timeout)
      @headers = headers.nil? ? {} : Utils.stringify_keys(Utils.hash!(headers, "headers"))
      @body_field = Utils.optional_string!(body_field, "body_field")
      @header_fields = header_fields.nil? ? [] : Utils.array!(header_fields, "header_fields").map(&:to_s)
      @timeout = timeout.nil? ? nil : Float(timeout)
      raise ValidationError.new("must not be negative", path: "retry_timeout") if @retry_timeout.negative?
      raise ValidationError.new("must be greater than zero", path: "timeout") if @timeout && !@timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "url" => url,
        "event_type" => event_type,
        "reconnect" => reconnect,
        "retry_timeout" => retry_timeout,
        "headers" => headers.empty? ? nil : Utils.deep_copy(headers),
        "body_field" => body_field,
        "header_fields" => header_fields.empty? ? nil : header_fields.dup,
        "timeout" => timeout
      ))
    end
  end
  SSECallTemplate = SseCallTemplate

  class StreamableHttpCallTemplate < CallTemplate
    include HTTPResponseLimits
    METHODS = %w[GET POST].freeze
    attr_accessor :url, :http_method, :content_type, :chunk_size, :timeout, :headers,
                  :body_field, :header_fields

    def initialize(url:, call_template_type: "streamable_http", http_method: "GET",
                   content_type: "application/octet-stream", chunk_size: 4096,
                   timeout: 60_000, headers: nil, body_field: nil,
                   header_fields: nil, **common)
      super(call_template_type: call_template_type, **common)
      @url = Utils.required_string!(url, "url")
      @http_method = http_method.to_s.upcase
      raise ValidationError.new("must be GET or POST", path: "http_method") unless METHODS.include?(@http_method)

      @content_type = Utils.required_string!(content_type, "content_type")
      @chunk_size = Integer(chunk_size)
      @timeout = Integer(timeout)
      @headers = headers.nil? ? {} : Utils.stringify_keys(Utils.hash!(headers, "headers"))
      @body_field = Utils.optional_string!(body_field, "body_field")
      @header_fields = header_fields.nil? ? [] : Utils.array!(header_fields, "header_fields").map(&:to_s)
      raise ValidationError.new("must be greater than zero", path: "chunk_size") unless @chunk_size.positive?
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "url" => url,
        "http_method" => http_method,
        "content_type" => content_type,
        "chunk_size" => chunk_size,
        "timeout" => timeout,
        "headers" => headers.empty? ? nil : Utils.deep_copy(headers),
        "body_field" => body_field,
        "header_fields" => header_fields.empty? ? nil : header_fields.dup
      ))
    end
  end
  StreamableHTTPCallTemplate = StreamableHttpCallTemplate

  class WebSocketCallTemplate < CallTemplate
    include ResponseLimits
    RESPONSE_FORMATS = %w[json text raw].freeze
    attr_accessor :url, :message, :protocol, :keep_alive, :response_format, :timeout,
                  :headers, :header_fields

    def initialize(url:, call_template_type: "websocket", message: nil, protocol: nil,
                   keep_alive: true, response_format: nil, timeout: 30,
                   headers: nil, header_fields: nil, **common)
      super(call_template_type: call_template_type, **common)
      @url = Utils.required_string!(url, "url")
      @message = Utils.deep_copy(message)
      @protocol = Utils.optional_string!(protocol, "protocol")
      @keep_alive = !!keep_alive
      @response_format = Utils.optional_string!(response_format, "response_format")
      if @response_format && !RESPONSE_FORMATS.include?(@response_format)
        raise ValidationError.new("must be json, text, or raw", path: "response_format")
      end
      @timeout = Float(timeout)
      @headers = headers.nil? ? {} : Utils.stringify_keys(Utils.hash!(headers, "headers"))
      @header_fields = header_fields.nil? ? [] : Utils.array!(header_fields, "header_fields").map(&:to_s)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "url" => url,
        "message" => Utils.deep_copy(message),
        "protocol" => protocol,
        "keep_alive" => keep_alive,
        "response_format" => response_format,
        "timeout" => timeout,
        "headers" => headers.empty? ? nil : Utils.deep_copy(headers),
        "header_fields" => header_fields.empty? ? nil : header_fields.dup
      ))
    end
  end
  WebsocketCallTemplate = WebSocketCallTemplate

  class GrpcCallTemplate < CallTemplate
    include ResponseLimits
    attr_accessor :host, :port, :service_name, :method_name, :target, :use_ssl,
                  :timeout, :metadata

    def initialize(host:, port:, call_template_type: "grpc", service_name: "grpcpb.UTCPService",
                   method_name: nil, target: nil, use_ssl: true, timeout: 30,
                   metadata: nil, **common)
      super(call_template_type: call_template_type, **common)
      @host = Utils.required_string!(host, "host")
      @port = Integer(port)
      @service_name = Utils.required_string!(service_name, "service_name")
      @method_name = Utils.optional_string!(method_name, "method_name")
      @target = Utils.optional_string!(target, "target")
      @use_ssl = !!use_ssl
      @timeout = Float(timeout)
      @metadata = metadata.nil? ? {} : Utils.stringify_keys(Utils.hash!(metadata, "metadata"))
      validate_network_values!
    end

    def to_h
      Utils.compact_hash(super.merge(
        "host" => host,
        "port" => port,
        "service_name" => service_name,
        "method_name" => method_name,
        "target" => target,
        "use_ssl" => use_ssl,
        "timeout" => timeout,
        "metadata" => metadata.empty? ? nil : Utils.deep_copy(metadata)
      ))
    end

    private

    def validate_network_values!
      raise ValidationError.new("must be between 1 and 65535", path: "port") unless (1..65_535).cover?(@port)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end
  end
  GRPCCallTemplate = GrpcCallTemplate

  class GraphQLCallTemplate < CallTemplate
    include ResponseLimits
    OPERATION_TYPES = %w[query mutation subscription].freeze
    attr_accessor :url, :operation_type, :operation_name, :headers, :header_fields,
                  :query, :variable_types, :selection_set, :timeout

    def initialize(url:, call_template_type: "graphql", operation_type: "query",
                   operation_name: nil, headers: nil, header_fields: nil, query: nil,
                   variable_types: nil, selection_set: nil, timeout: 30, **common)
      super(call_template_type: call_template_type, **common)
      @url = Utils.required_string!(url, "url")
      @operation_type = operation_type.to_s
      unless OPERATION_TYPES.include?(@operation_type)
        raise ValidationError.new("must be query, mutation, or subscription", path: "operation_type")
      end
      @operation_name = Utils.optional_string!(operation_name, "operation_name")
      @headers = headers.nil? ? {} : Utils.stringify_keys(Utils.hash!(headers, "headers"))
      @header_fields = header_fields.nil? ? [] : Utils.array!(header_fields, "header_fields").map(&:to_s)
      @query = Utils.optional_string!(query, "query")
      @variable_types = variable_types.nil? ? {} : Utils.stringify_keys(Utils.hash!(variable_types, "variable_types"))
      @selection_set = Utils.optional_string!(selection_set, "selection_set")
      @timeout = Float(timeout)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "url" => url,
        "operation_type" => operation_type,
        "operation_name" => operation_name,
        "headers" => headers.empty? ? nil : Utils.deep_copy(headers),
        "header_fields" => header_fields.empty? ? nil : header_fields.dup,
        "query" => query,
        "variable_types" => variable_types.empty? ? nil : Utils.deep_copy(variable_types),
        "selection_set" => selection_set,
        "timeout" => timeout
      ))
    end
  end
  GraphqlCallTemplate = GraphQLCallTemplate

  class TcpCallTemplate < CallTemplate
    include ResponseLimits
    FORMATS = %w[json text].freeze
    FRAMING = %w[length_prefix delimiter fixed_length stream].freeze
    attr_accessor :host, :port, :request_data_format, :request_data_template,
                  :response_byte_format, :framing_strategy, :length_prefix_bytes,
                  :length_prefix_endian, :message_delimiter, :interpret_escape_sequences,
                  :fixed_message_length, :max_response_size, :timeout

    def initialize(host:, port:, call_template_type: "tcp", request_data_format: "json",
                   request_data_template: nil, response_byte_format: "utf-8",
                   framing_strategy: "stream", length_prefix_bytes: 4,
                   length_prefix_endian: "big", message_delimiter: "\\x00",
                   interpret_escape_sequences: true, fixed_message_length: nil,
                   max_response_size: 65_536, timeout: 30_000, **common)
      super(call_template_type: call_template_type, auth: nil, **common)
      @host = Utils.required_string!(host, "host")
      @port = Integer(port)
      @request_data_format = request_data_format.to_s
      @request_data_template = Utils.optional_string!(request_data_template, "request_data_template")
      @response_byte_format = response_byte_format.nil? ? nil : response_byte_format.to_s
      @framing_strategy = framing_strategy.to_s
      @length_prefix_bytes = Integer(length_prefix_bytes)
      @length_prefix_endian = length_prefix_endian.to_s
      @message_delimiter = message_delimiter.to_s
      @interpret_escape_sequences = !!interpret_escape_sequences
      @fixed_message_length = fixed_message_length.nil? ? nil : Integer(fixed_message_length)
      @max_response_size = Integer(max_response_size)
      @timeout = Integer(timeout)
      validate_socket_values!
    end

    def to_h
      Utils.compact_hash(super.merge(
        "host" => host,
        "port" => port,
        "request_data_format" => request_data_format,
        "request_data_template" => request_data_template,
        "response_byte_format" => response_byte_format,
        "framing_strategy" => framing_strategy,
        "length_prefix_bytes" => length_prefix_bytes,
        "length_prefix_endian" => length_prefix_endian,
        "message_delimiter" => message_delimiter,
        "interpret_escape_sequences" => interpret_escape_sequences,
        "fixed_message_length" => fixed_message_length,
        "max_response_size" => max_response_size,
        "timeout" => timeout
      ))
    end

    private

    def validate_socket_values!
      raise ValidationError.new("must be between 1 and 65535", path: "port") unless (1..65_535).cover?(@port)
      raise ValidationError.new("must be json or text", path: "request_data_format") unless FORMATS.include?(@request_data_format)
      raise ValidationError.new("unsupported framing strategy", path: "framing_strategy") unless FRAMING.include?(@framing_strategy)
      raise ValidationError.new("must be 1, 2, 4, or 8", path: "length_prefix_bytes") unless [1, 2, 4, 8].include?(@length_prefix_bytes)
      raise ValidationError.new("must be big or little", path: "length_prefix_endian") unless %w[big little].include?(@length_prefix_endian)
      if @framing_strategy == "fixed_length" && (!@fixed_message_length || !@fixed_message_length.positive?)
        raise ValidationError.new("must be positive for fixed_length framing", path: "fixed_message_length")
      end
      raise ValidationError.new("must be greater than zero", path: "max_response_size") unless @max_response_size.positive?
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end
  end
  TCPCallTemplate = TcpCallTemplate

  class UdpCallTemplate < CallTemplate
    include ResponseLimits
    FORMATS = %w[json text].freeze
    attr_accessor :host, :port, :number_of_response_datagrams, :request_data_format,
                  :request_data_template, :response_byte_format, :timeout

    def initialize(host:, port:, call_template_type: "udp", number_of_response_datagrams: 1,
                   request_data_format: "json", request_data_template: nil,
                   response_byte_format: "utf-8", timeout: 30_000, **common)
      super(call_template_type: call_template_type, auth: nil, **common)
      @host = Utils.required_string!(host, "host")
      @port = Integer(port)
      @number_of_response_datagrams = Integer(number_of_response_datagrams)
      @request_data_format = request_data_format.to_s
      @request_data_template = Utils.optional_string!(request_data_template, "request_data_template")
      @response_byte_format = response_byte_format.nil? ? nil : response_byte_format.to_s
      @timeout = Integer(timeout)
      raise ValidationError.new("must be between 1 and 65535", path: "port") unless (1..65_535).cover?(@port)
      raise ValidationError.new("must not be negative", path: "number_of_response_datagrams") if @number_of_response_datagrams.negative?
      raise ValidationError.new("must be json or text", path: "request_data_format") unless FORMATS.include?(@request_data_format)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "host" => host,
        "port" => port,
        "number_of_response_datagrams" => number_of_response_datagrams,
        "request_data_format" => request_data_format,
        "request_data_template" => request_data_template,
        "response_byte_format" => response_byte_format,
        "timeout" => timeout
      ))
    end
  end
  UDPCallTemplate = UdpCallTemplate

  class WebRtcCallTemplate < CallTemplate
    include ResponseLimits
    attr_accessor :signaling_server, :peer_id, :data_channel_name, :timeout, :ice_servers,
                  :max_pending_requests

    def initialize(signaling_server:, peer_id:, data_channel_name:, call_template_type: "webrtc",
                   timeout: 30, ice_servers: nil, max_pending_requests: 1024, **common)
      super(call_template_type: call_template_type, auth: nil, **common)
      @signaling_server = Utils.required_string!(signaling_server, "signaling_server")
      @peer_id = Utils.required_string!(peer_id, "peer_id")
      @data_channel_name = Utils.required_string!(data_channel_name, "data_channel_name")
      @timeout = Float(timeout)
      @max_pending_requests = Integer(max_pending_requests)
      @ice_servers = ice_servers.nil? ? [] : Utils.array!(ice_servers, "ice_servers").map do |server|
        Utils.stringify_keys(Utils.hash!(server, "ice_server"))
      end
      raise ValidationError.new("must be finite and greater than zero", path: "timeout") unless @timeout.finite? && @timeout.positive?
      raise ValidationError.new("must be greater than zero", path: "max_pending_requests") unless @max_pending_requests.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "signaling_server" => signaling_server,
        "peer_id" => peer_id,
        "data_channel_name" => data_channel_name,
        "max_pending_requests" => max_pending_requests,
        "timeout" => timeout,
        "ice_servers" => ice_servers.empty? ? nil : Utils.deep_copy(ice_servers)
      ))
    end
  end
  WebRTCCallTemplate = WebRtcCallTemplate

  class McpCallTemplate < CallTemplate
    include ResponseLimits
    attr_accessor :config, :register_resources_as_tools, :protocol_version, :timeout

    def initialize(config:, call_template_type: "mcp", register_resources_as_tools: false,
                   protocol_version: "2025-06-18", timeout: 30, **common)
      super(call_template_type: call_template_type, **common)
      @config = Utils.stringify_keys(Utils.hash!(config, "config"))
      servers = @config["mcpServers"]
      unless servers.is_a?(Hash) && !servers.empty?
        raise ValidationError.new("must contain a non-empty mcpServers object", path: "config")
      end
      @register_resources_as_tools = !!register_resources_as_tools
      @protocol_version = Utils.required_string!(protocol_version, "protocol_version")
      @timeout = Float(timeout)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def servers
      config["mcpServers"]
    end

    def to_h
      super.merge(
        "config" => Utils.deep_copy(config),
        "register_resources_as_tools" => register_resources_as_tools,
        "protocol_version" => protocol_version,
        "timeout" => timeout
      )
    end
  end
  MCPCallTemplate = McpCallTemplate

  class CommandStep
    include ModelSerialization
    attr_accessor :command, :append_to_final_output

    def self.from_h(value)
      return value if value.is_a?(self)

      new(**Utils.symbolize_keys(Utils.stringify_keys(Utils.hash!(value, "command step"))))
    end

    def initialize(command:, append_to_final_output: nil, **_extra)
      @command = Utils.required_string!(command, "command")
      unless append_to_final_output.nil? || append_to_final_output == true || append_to_final_output == false
        raise ValidationError.new("must be true, false, or null", path: "append_to_final_output")
      end
      @append_to_final_output = append_to_final_output
    end

    def to_h
      Utils.compact_hash("command" => command, "append_to_final_output" => append_to_final_output)
    end
  end

  class CliCallTemplate < CallTemplate
    attr_accessor :commands, :env_vars, :inherit_env_vars, :working_dir, :timeout

    def initialize(commands:, call_template_type: "cli", env_vars: nil, inherit_env_vars: nil,
                   working_dir: nil, timeout: 120, **common)
      super(call_template_type: call_template_type, **common)
      @commands = Utils.array!(commands, "commands").map { |item| CommandStep.from_h(item) }
      raise ValidationError.new("must contain at least one command", path: "commands") if @commands.empty?

      @env_vars = env_vars.nil? ? {} : Utils.stringify_keys(Utils.hash!(env_vars, "env_vars"))
      @inherit_env_vars = inherit_env_vars.nil? ? nil : Utils.array!(inherit_env_vars, "inherit_env_vars").map(&:to_s)
      @working_dir = Utils.optional_string!(working_dir, "working_dir")
      @timeout = Float(timeout)
      raise ValidationError.new("must be greater than zero", path: "timeout") unless @timeout.positive?
    end

    def to_h
      Utils.compact_hash(super.merge(
        "commands" => commands.map(&:to_h),
        "env_vars" => env_vars.empty? ? nil : Utils.deep_copy(env_vars),
        "inherit_env_vars" => inherit_env_vars&.dup,
        "working_dir" => working_dir,
        "timeout" => timeout
      ))
    end
  end

  class TextCallTemplate < CallTemplate
    attr_accessor :content, :base_url, :auth_tools

    def initialize(content:, call_template_type: "text", base_url: nil, auth_tools: nil, **common)
      super(call_template_type: call_template_type, auth: nil, **common)
      @content = Utils.required_string!(content, "content")
      @base_url = Utils.optional_string!(base_url, "base_url")
      @auth_tools = auth_tools.nil? ? nil : Auth.from_h(auth_tools)
    end

    def to_h
      Utils.compact_hash(super.merge(
        "content" => content,
        "base_url" => base_url,
        "auth_tools" => auth_tools&.to_h
      ))
    end
  end

  class FileCallTemplate < CallTemplate
    attr_accessor :file_path, :auth_tools

    def initialize(file_path:, call_template_type: "file", auth_tools: nil, **common)
      super(call_template_type: call_template_type, auth: nil, **common)
      @file_path = Utils.required_string!(file_path, "file_path")
      @auth_tools = auth_tools.nil? ? nil : Auth.from_h(auth_tools)
    end

    def to_h
      Utils.compact_hash(super.merge("file_path" => file_path, "auth_tools" => auth_tools&.to_h))
    end
  end

  class Tool
    include ModelSerialization
    attr_accessor :name, :description, :inputs, :outputs, :tags, :average_response_size,
                  :tool_call_template

    def self.from_h(value)
      return value if value.is_a?(self)

      data = Utils.stringify_keys(Utils.hash!(value, "tool"))
      new(**Utils.symbolize_keys(data))
    rescue ValidationError
      raise
    rescue StandardError => error
      raise SerializerValidationError, "Invalid tool: #{error.message}"
    end

    def initialize(name:, tool_call_template:, description: "", inputs: nil, outputs: nil,
                   tags: nil, average_response_size: nil, **extra)
      @name = Utils.required_string!(name, "tool.name")
      @description = Utils.optional_string!(description, "tool.description") || ""
      @inputs = JsonSchema.from_h(inputs || {})
      @outputs = JsonSchema.from_h(outputs || {})
      @tags = (tags || []).tap { |value| Utils.array!(value, "tool.tags") }.map(&:to_s)
      @average_response_size = average_response_size.nil? ? nil : Integer(average_response_size)
      @tool_call_template = CallTemplate.from_h(tool_call_template)
      @extra = Utils.stringify_keys(extra)
    end

    def to_h
      Utils.compact_hash({
        "name" => name,
        "description" => description,
        "inputs" => inputs.to_h,
        "outputs" => outputs.to_h,
        "tags" => tags.dup,
        "average_response_size" => average_response_size,
        "tool_call_template" => tool_call_template.to_h
      }.merge(Utils.deep_copy(@extra)))
    end
  end

  class Manual
    include ModelSerialization
    attr_accessor :utcp_version, :manual_version, :info, :tools

    def self.from_h(value)
      return value if value.is_a?(self)

      data = Utils.stringify_keys(Utils.hash!(value, "manual"))
      new(**Utils.symbolize_keys(data))
    rescue ValidationError
      raise
    rescue StandardError => error
      raise SerializerValidationError, "Invalid UTCP manual: #{error.message}"
    end

    def initialize(tools:, utcp_version: VERSION, manual_version: "1.0.0", info: nil, **extra)
      @utcp_version = Utils.required_string!(utcp_version, "utcp_version")
      @manual_version = Utils.required_string!(manual_version, "manual_version")
      @info = info.nil? ? {} : Utils.stringify_keys(Utils.hash!(info, "info"))
      @tools = Utils.array!(tools, "tools").map { |tool| Tool.from_h(tool) }
      @extra = Utils.stringify_keys(extra)
    end

    def to_h
      values = {
        "manual_version" => manual_version,
        "utcp_version" => utcp_version,
        "info" => info.empty? ? nil : Utils.deep_copy(info),
        "tools" => tools.map(&:to_h)
      }.merge(Utils.deep_copy(@extra))
      Utils.compact_hash(values)
    end

  end
  UtcpManual = Manual

  class RegisterManualResult
    include ModelSerialization
    attr_accessor :manual_call_template, :manual, :success, :errors

    def initialize(manual_call_template:, manual:, success:, errors: [])
      @manual_call_template = CallTemplate.from_h(manual_call_template)
      @manual = Manual.from_h(manual)
      @success = !!success
      @errors = Array(errors).map(&:to_s)
    end

    def success?
      success
    end

    def to_h
      {
        "manual_call_template" => manual_call_template.to_h,
        "manual" => manual.to_h,
        "success" => success,
        "errors" => errors.dup
      }
    end
  end
end
