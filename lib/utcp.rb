# frozen_string_literal: true

require_relative "utcp/version"
require_relative "utcp/errors"
require_relative "utcp/utils"
require_relative "utcp/registry"
require_relative "utcp/models"
require_relative "utcp/repository"
require_relative "utcp/variables"
require_relative "utcp/config"
require_relative "utcp/serializer"
require_relative "utcp/protocols/base"
require_relative "utcp/openapi_converter"
require_relative "utcp/migration"
require_relative "utcp/protocols/http"
require_relative "utcp/protocols/http_stream_support"
require_relative "utcp/protocols/sse"
require_relative "utcp/protocols/streamable_http"
require_relative "utcp/protocols/cli"
require_relative "utcp/protocols/text"
require_relative "utcp/protocols/file"
require_relative "utcp/protocols/websocket"
require_relative "utcp/protocols/graphql"
require_relative "utcp/protocols/grpc"
require_relative "utcp/protocols/socket_support"
require_relative "utcp/protocols/tcp"
require_relative "utcp/protocols/udp"
require_relative "utcp/protocols/mcp"
require_relative "utcp/protocols/webrtc"
require_relative "utcp/client"
require_relative "utcp/code_mode"

module UTCP
  register_auth("api_key", ApiKeyAuth)
  register_auth("basic", BasicAuth)
  register_auth("oauth2", OAuth2Auth)

  register_call_template("http", HttpCallTemplate)
  register_call_template("sse", SseCallTemplate)
  register_call_template("streamable_http", StreamableHttpCallTemplate)
  register_call_template("http_stream", StreamableHttpCallTemplate)
  register_call_template("cli", CliCallTemplate)
  register_call_template("websocket", WebSocketCallTemplate)
  register_call_template("grpc", GrpcCallTemplate)
  register_call_template("graphql", GraphQLCallTemplate)
  register_call_template("tcp", TcpCallTemplate)
  register_call_template("udp", UdpCallTemplate)
  register_call_template("webrtc", WebRtcCallTemplate)
  register_call_template("mcp", McpCallTemplate)
  register_call_template("text", TextCallTemplate)
  register_call_template("file", FileCallTemplate)

  register_protocol("http", HTTPProtocol.new)
  register_protocol("sse", SSEProtocol.new)
  streamable_http_protocol = StreamableHTTPProtocol.new
  register_protocol("streamable_http", streamable_http_protocol)
  register_protocol("http_stream", streamable_http_protocol)
  register_protocol("cli", CLIProtocol.new)
  register_protocol("websocket", WebSocketProtocol.new)
  register_protocol("grpc", GRPCProtocol.new)
  register_protocol("graphql", GraphQLProtocol.new)
  register_protocol("tcp", TCPProtocol.new)
  register_protocol("udp", UDPProtocol.new)
  register_protocol("webrtc", WebRTCProtocol.new)
  register_protocol("mcp", MCPProtocol.new)
  register_protocol("text", TextProtocol.new)
  register_protocol("file", FileProtocol.new)
end

# Conventional Ruby casing alias for applications that do not preserve acronyms.
Utcp = UTCP unless defined?(Utcp)
