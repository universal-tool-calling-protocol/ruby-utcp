# ruby-utcp

`ruby-utcp` is a Ruby implementation of the Universal Tool Calling Protocol (UTCP) 1.1. It discovers tools from UTCP manuals, stores and searches them locally, and calls them directly over their native protocol.

The implementation follows the UTCP [v0.1 to v1.0 migration guide](https://www.utcp.io/migration-v0.1-to-v1.0) and [v1.0 to v1.1 migration guide](https://www.utcp.io/migration-v1.0-to-v1.1). It includes the v1 plugin architecture, structured data models, authentication, variable loading, protocol-specific errors, and the v1.1 secure-by-default protocol allow-list.

## Installation

Add the gem to your bundle:

```ruby
gem "ruby-utcp"
```

Or build this checkout:

```sh
gem build ruby-utcp.gemspec
gem install ./ruby-utcp-1.1.0.gem
```

Ruby 2.6 or newer is supported for the core and 11 transports. The WebRTC default backend uses the optional `webrtc-ruby` gem, which requires Ruby 3.1 and `libdatachannel`; an application can instead inject its own peer adapter. The gRPC transport similarly loads the optional `grpc` gem only when used. There are no mandatory runtime dependencies outside Ruby's standard library.

## Quick start

```ruby
require "utcp"

client = UTCP::Client.create(
  config: {
    manual_call_templates: [
      {
        name: "weather_service",
        call_template_type: "http",
        url: "https://weather.example.com/utcp",
        http_method: "GET"
      }
    ],
    variables: {
      WEATHER_API_KEY: ENV.fetch("WEATHER_API_KEY")
    }
  }
)

client.list_tools.each { |tool| puts tool.name }
result = client.call_tool("weather_service.get_weather", location: "Warsaw")
```

`Client.create` registers the configured manuals before returning. Ruby calls are synchronous; `register_manual`, `search_tools`, and `call_tool` return their results directly.

## UTCP 1.1 manuals

A manual describes tools and gives each tool its own call template:

```json
{
  "manual_version": "1.0.0",
  "utcp_version": "1.1.0",
  "info": {
    "title": "Weather API",
    "version": "1.0.0"
  },
  "tools": [
    {
      "name": "get_weather",
      "description": "Get current weather",
      "inputs": {
        "type": "object",
        "properties": {
          "location": { "type": "string" }
        },
        "required": ["location"]
      },
      "outputs": { "type": "object" },
      "tags": ["weather"],
      "tool_call_template": {
        "call_template_type": "http",
        "url": "https://api.example.com/weather/{location}",
        "http_method": "GET"
      }
    }
  ]
}
```

Registered names are qualified as `manual_name.tool_name`.

## Secure-by-default protocol rules

UTCP 1.1 limits tools to the protocol used to discover their manual. An HTTP manual therefore registers HTTP tools by default and filters out CLI, text, and other tools.

Mixed-protocol manuals must opt in explicitly:

```ruby
{
  name: "mixed_tools",
  call_template_type: "http",
  url: "https://example.com/utcp",
  allowed_communication_protocols: %w[http cli]
}
```

The client checks this policy during both registration and every call. An omitted or empty allow-list means only the manual's own protocol is allowed.

## All 12 transports

The gem registers all twelve transports present in the UTCP reference implementations. `file` remains available as an additional Ruby extension.

| Type | Call template | Behavior |
| --- | --- | --- |
| `http` | `HttpCallTemplate` | REST, OpenAPI discovery, redirects, auth |
| `sse` | `SseCallTemplate` | filtered Server-Sent Events and streaming enumeration |
| `streamable_http` | `StreamableHttpCallTemplate` | NDJSON, JSON Sequence, JSON, and binary chunks |
| `cli` | `CliCallTemplate` | safe argument interpolation and multi-step shell calls |
| `websocket` | `WebSocketCallTemplate` | RFC 6455 client, WSS security, persistent connections |
| `grpc` | `GrpcCallTemplate` | UTCP protobuf `GetManual`, `CallTool`, and server streaming |
| `graphql` | `GraphQLCallTemplate` | introspection, queries, mutations, and subscriptions |
| `tcp` | `TcpCallTemplate` | length-prefix, delimiter, fixed-size, and stream framing |
| `udp` | `UdpCallTemplate` | zero, one, or multiple response datagrams |
| `webrtc` | `WebRtcCallTemplate` | signaling plus request-correlated DataChannel messages |
| `mcp` | `McpCallTemplate` | MCP JSON-RPC over stdio or Streamable HTTP |
| `text` | `TextCallTemplate` | inline UTCP/OpenAPI documents and static text tools |

Complete runnable/configuration examples are in [examples/README.md](examples/README.md), with one file per transport.

Run `make` to start every available matching local server, execute its clients, and cleanly stop the servers. Missing optional gRPC/WebRTC backends are reported and skipped. `make full-demo` is the strict 12/12 target; `make standard-demo` always runs only the pairs that do not need native backends.

### HTTP, SSE, and Streamable HTTP

HTTP templates support URL path parameters, query parameters, JSON or text bodies, input-to-header mapping, API keys, Basic auth, and OAuth2 client credentials.

```ruby
{
  call_template_type: "http",
  url: "https://api.example.com/users/{user_id}",
  http_method: "PATCH",
  body_field: "body",
  header_fields: ["X-Request-ID"],
  auth: {
    auth_type: "api_key",
    api_key: "${API_TOKEN}",
    var_name: "Authorization",
    location: "header"
  }
}
```

Remote HTTP endpoints must use HTTPS. Plain HTTP is accepted only for loopback hosts, which keeps local development convenient. Redirect targets are checked again and credentials are removed on cross-origin redirects.

An HTTP, text, or file manual may also contain an OpenAPI 3 or Swagger 2 document. It is converted into UTCP tools automatically.

SSE and Streamable HTTP reuse the same URL, header, body, and auth conventions. Their streaming forms expose ordinary Ruby enumerators:

```ruby
client.call_tool_streaming("events.watch", topic: "builds").each do |event|
  puts event.inspect
end
```

`streamable_http` is the v1 call-template discriminator. `http_stream` is also accepted as a compatibility alias for the Go reference implementation.

### CLI

```ruby
{
  call_template_type: "cli",
  commands: [
    { command: "prepare-data", append_to_final_output: false },
    { command: "weather UTCP_ARG_city_UTCP_END", append_to_final_output: true }
  ],
  env_vars: { "MODE" => "production" },
  inherit_env_vars: ["PATH"],
  working_dir: "/srv/tools"
}
```

Commands run in one `/bin/sh` process, so working-directory changes and `$CMD_0_OUTPUT` references persist. Tool arguments are passed through dedicated environment variables after the shell parses the trusted command template, preventing argument values from injecting shell syntax. The child receives only a small default environment allow-list unless `inherit_env_vars` is set.

Only register CLI tools from manuals you trust: the command template itself is executable code.

### WebSocket and GraphQL

WebSocket is implemented directly on Ruby sockets with RFC 6455 masking, fragmentation, ping/pong, TLS certificate verification, handshake verification, Basic/API-key/OAuth2 auth, and configurable JSON/text/binary responses. Plain `ws://` is restricted to literal loopback hosts.

GraphQL registration introspects query, mutation, and subscription roots. A discovered operation gets input/output schemas and a generated query; set `query`, `variable_types`, or `selection_set` on an explicit call template when the endpoint needs a custom selection:

```ruby
{
  call_template_type: "graphql",
  url: "https://api.example.com/graphql",
  operation_type: "query",
  operation_name: "user",
  query: "query User($id: ID!) { user(id: $id) { id name } }"
}
```

Subscriptions use the `graphql-transport-ws` subprotocol through `call_tool_streaming`.

### TCP and UDP

Socket templates can send JSON arguments or a text template containing `UTCP_ARG_name_UTCP_ARG`. TCP supports `length_prefix`, `delimiter`, `fixed_length`, and `stream` framing. UDP supports a configurable number of response datagrams, including zero for fire-and-forget calls. Timeouts are expressed in milliseconds in both templates.

### gRPC

The gRPC transport interoperates with the reference `grpcpb.UTCPService`:

- `GetManual(Empty) returns (Manual)`
- `CallTool(ToolCallRequest) returns (ToolCallResponse)`
- `CallToolStream(ToolCallRequest) returns (stream ToolCallResponse)`

Add `gem "grpc"` to the consuming application. The protocol uses a tiny built-in protobuf codec for these UTCP messages, so generated Ruby classes are not required. A custom RPC adapter can be passed as `UTCP::GRPCProtocol.new(rpc_client_factory: ...)`.

The checked-in contract is [`proto/utcp.proto`](proto/utcp.proto). Its committed Python stubs are generated by `make grpc-python-generate` and shared by [`examples/servers/grpc_server.py`](examples/servers/grpc_server.py) and [`examples/grpc_python.py`](examples/grpc_python.py). Run both the Ruby and Python clients against the Python server with `make grpc-python-demo`.

### MCP

MCP sessions implement initialization, notifications, `tools/list`, `tools/call`, optional `resources/list`/`resources/read`, session IDs, and both stdio and Streamable HTTP transports. With several servers, registered names use `manual.server.tool`:

```ruby
{
  name: "bridge",
  call_template_type: "mcp",
  config: {
    mcpServers: {
      local: { command: "ruby", args: ["server.rb"] },
      remote: { transport: "http", url: "https://mcp.example.com/mcp" }
    }
  }
}
```

### WebRTC

WebRTC follows the reference signaling contract: `POST /connect` exchanges SDP and returns `sdp`, `candidates`, and `tools`; `POST /candidate` exchanges ICE candidates. DataChannel requests are JSON envelopes containing `id`, `tool`, and `args`, and responses correlate the same `id` with `result`.

The built-in peer uses `webrtc-ruby` and `libdatachannel`. For another native stack, pass `peer_factory:` to `UTCP::WebRTCProtocol`; the adapter contract is demonstrated by the protocol tests.

### Text and file

Text templates parse a manual supplied directly in `content`. File templates read JSON or safe YAML relative to the client's `root_dir`.

```ruby
UTCP::Client.create(config: {
  manual_call_templates: [
    { name: "local", call_template_type: "file", file_path: "tools.json" }
  ]
})
```

## Variables and `.env` files

`${NAME}` and `$NAME` placeholders are resolved in this order:

1. `config.variables`
2. configured variable loaders
3. the process environment

```yaml
variables:
  HOST: api.example.com
load_variables_from:
  - variable_loader_type: dotenv
    env_file_path: .env
```

Manual-specific names are tried first. For a manual named `weather_api`, `${TOKEN}` first looks for `weather__api_TOKEN`, then `TOKEN`. Use `get_required_variables_for_manual_and_tools` or `get_required_variables_for_registered_tool` to inspect requirements without exposing values.

## Migrating v0.1 documents

The helpers are non-destructive and return string-keyed hashes ready for `Client.create` or `Manual.from_h`:

```ruby
config_1_1 = UTCP::Migration.config_v0_1_to_v1_1(old_config)
manual_1_1 = UTCP::Migration.manual_v0_1_to_v1_1(old_manual)

client = UTCP::Client.create(config: config_1_1)
manual = UTCP::Manual.from_h(manual_1_1)
```

They rename `providers` to `manual_call_templates`, `provider_type` to `call_template_type`, `parameters` to `inputs`, `provider` to `tool_call_template`, and convert legacy CLI command arguments to `UTCP_ARG_name_UTCP_END` placeholders.

## Search and repositories

The default thread-safe in-memory repository supports tool and manual lookup. Search ranks tag, name, and description matches:

```ruby
client.search_tools("weather forecast", limit: 5, any_of_tags_required: ["weather"])
```

Pass objects that implement the repository or search interfaces through `tool_repository` and `tool_search_strategy` to replace the defaults.

## Code Mode

`CodeModeUtcpClient` can run a multi-step Ruby workflow as one call. Tools are invoked through the explicit `codemode` runtime API, and the final expression (or an explicit `return`) becomes the result:

```ruby
client = UTCP::CodeModeUtcpClient.create(config: config)

execution = client.call_tool_chain(<<~'RUBY', timeout: 30)
  weather = codemode.call_tool("weather_service.get_weather", location: "Warsaw")
  alerts = weather["alerts"].select { |alert| alert["severity"] == "high" }
  puts "Found #{alerts.length} high-severity alerts"
  { temperature: weather["temperature"], alerts: alerts }
RUBY

puts execution["result"]
puts execution["logs"]
```

Use `codemode.call_tool_stream` to collect a streaming call into an array. `codemode.search_tools`, `codemode.get_tool_interface`, and `codemode.interfaces` provide progressive discovery inside a workflow. `codemode.get(value, key, default)` safely reads dynamic results, and `get_all_tools_ruby_interfaces` provides the tool catalog outside the sandbox.

Code Mode accepts a constrained Ruby subset for local variables, JSON-like literals, arithmetic, conditionals, loops, indexing, and common collection transforms. It is interpreted without `eval`; filesystem, process, constant, reflection, import, and direct network APIs are not exposed. Executions also have code-size, step, result-size, log-size, and wall-clock limits. External effects remain possible through the UTCP tools that you deliberately register.

## Custom protocol plugins

Register a call-template class and a protocol implementation before creating a client:

```ruby
class QueueTemplate < UTCP::CallTemplate
  attr_reader :queue

  def initialize(queue:, call_template_type: "queue", **options)
    super(call_template_type: call_template_type, **options)
    @queue = queue
  end

  def to_h
    super.merge("queue" => queue)
  end
end

class QueueProtocol < UTCP::CommunicationProtocol
  def register_manual(client, template)
    # Return UTCP::RegisterManualResult
  end

  def deregister_manual(client, template); end

  def call_tool(client, name, arguments, template)
    # Invoke the queue's native API
  end
end

UTCP.register_call_template("queue", QueueTemplate)
UTCP.register_protocol("queue", QueueProtocol.new)
```

## Development

```sh
rake test
gem build ruby-utcp.gemspec
```
