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
gem install "./ruby-utcp-$(ruby -Ilib -rutcp/version -e 'print UTCP::VERSION').gem"
```

Ruby 2.6 or newer is supported for the core and 11 transports. The WebRTC default backend uses the optional `webrtc-ruby` gem, which requires Ruby 3.1 and `libdatachannel`; an application can instead inject its own peer adapter. The gRPC transport similarly loads the optional `grpc` gem only when used. `base64` and `logger` are declared runtime dependencies so Bundler can load them on Ruby versions where they are distributed as separate gems; the remaining core libraries come with Ruby.

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

### Response limits

All transports except `file`, `cli`, and `text` include `UTCP::ResponseLimits`. Set `max_response_bytes` on a call template to bound incoming responses; the default is **100 MiB (104,857,600 bytes)**. The value must be positive and is preserved when templates are serialized. Discovery responses are bounded as well as tool responses. Exceeding the limit aborts the read with a UTCP error; responses are never silently truncated.

```ruby
template = UTCP::HttpCallTemplate.new(
  url: "https://api.example.com/results",
  max_response_bytes: 2 * 1024 * 1024
)
```

The budget counts response bytes before JSON/protobuf decoding, including protocol envelopes but excluding transport framing such as WebSocket frame headers and TCP length prefixes/delimiters. HTTP counts decompressed body bytes. SSE, Streamable HTTP, gRPC streams, GraphQL subscriptions (including control messages), and UDP calls share one budget across their response items. MCP limits each JSON-RPC exchange, including stdio notifications and line separators; discovery additionally bounds the serialized results collected across pages and servers. TCP also retains its existing `max_response_size` limit; the smaller limit applies. WebRTC limits both signaling bodies and data-channel messages. Custom adapters are checked when they return their data and must enforce read limits themselves to prevent buffering oversized data internally.

HTTP, SSE, and Streamable HTTP templates also accept `total_timeout` in seconds. Buffered HTTP exchanges, including redirects, default to the request timeout as a total deadline. Collecting an SSE or Streamable HTTP response with `call_tool` also has a total deadline. Direct `call_tool_streaming` enumeration has a total deadline only when `total_timeout` is set; the existing read timeout still applies between network reads. SSE and Streamable HTTP additionally default to `max_event_bytes: 1_048_576` and `max_response_items: 10_000`. These bound individual events/records and the number of emitted values; binary output is split into bounded chunks. Breaking out of an HTTP stream, GraphQL subscription, or gRPC stream releases its connection or cancels its RPC.

### Authentication by transport

| Transport | Supported `auth` | Authentication checks |
| --- | --- | --- |
| HTTP | API key in header/query/cookie, Basic, OAuth2 | Discovery and calls; strips credentials on cross-origin redirects |
| SSE | API key in header/query/cookie, Basic, OAuth2 | Discovery and streaming; streaming redirects are rejected |
| Streamable HTTP (`streamable_http`, alias `http_stream`) | API key in header/query/cookie, Basic, OAuth2 | Discovery and streaming; streaming redirects are rejected |
| WebSocket | API key in header/query/cookie, Basic, OAuth2 | Handshake; connections are separated by client and effective credentials |
| GraphQL | API key in header/query/cookie, Basic, OAuth2 | Introspection, queries/mutations and WebSocket subscriptions |
| gRPC | API key with `location: "header"` mapped to metadata, Basic, OAuth2 | Discovery, unary calls and server streams |
| MCP HTTP | API key in header/query/cookie, Basic, OAuth2 | Initialization, discovery and calls; sessions are separated by client, endpoint and credentials |
| MCP stdio | No built-in `auth` support | Rejects `auth` before starting a process; configure the server's own credentials through its environment |
| CLI | No built-in `auth` support | Rejects `auth`; the invoked command can use explicit `env_vars` |
| TCP | No built-in `auth` support | Rejects `auth` before socket I/O; application message authentication is caller-defined |
| UDP | No built-in `auth` support | Rejects `auth` before socket I/O; application message authentication is caller-defined |
| WebRTC | No built-in `auth` support | Rejects `auth` before creating a peer; signaling authentication is not implemented |
| Text | No transport `auth` | Rejects `auth`; `auth_tools` can configure tools converted from OpenAPI |
| File | No transport `auth` | Rejects `auth` before reading a file; `auth_tools` can configure tools converted from OpenAPI |

Unsupported auth configuration raises `AuthenticationError` on calls and makes manual registration fail. HTTP/WebSocket 401/403 and native gRPC UNAUTHENTICATED/PERMISSION_DENIED errors are reported as `AuthenticationError`. Invalid header/cookie API keys containing CR/LF are rejected before transport I/O. MCP session IDs are stripped on cross-origin redirects; changed auth or static server headers create a fresh, initialized session. Custom MCP session factories are responsible for their own authentication.

The default suite tests the auth matrix at transport boundaries and uses local HTTP/WebSocket servers for wire-level checks. Native gRPC checks additionally run with `UTCP_NATIVE_TESTS=1 bundle exec rake native TESTOPTS='--name /NativeGRPCTest/'`; this subset does not require loading the WebRTC backend.

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

Cross-origin redirects remove explicit `Authorization`, `Proxy-Authorization`, and `Cookie` headers as well as headers supplied by the auth configuration. OAuth2 token requests follow redirects only within the same origin (scheme, host, and port), so client credentials cannot be forwarded to another origin. Cached OAuth2 tokens are keyed by the token URL, client ID, client secret, and scope; changing credentials requires a new token request.

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

Sessions and resource mappings are isolated per client. Closing one client does not close another client's sessions, even when manual and server names match. Tool and resource discovery follows all result pages. An MCP result with `isError: true` raises `UTCP::ToolCallError`; the original result is available in `error.response_body`.

For stdio, `timeout` bounds the complete request write and response read, including partial lines and intervening notifications. Outgoing messages are limited to 16 MiB; incoming messages and notifications share the template's `max_response_bytes` budget. Stderr is drained while retaining only its last 64 KiB. Call `client.close` when finished to release server processes.

### WebRTC

WebRTC follows the reference signaling contract: `POST /connect` exchanges SDP and returns `sdp`, `candidates`, and `tools`; `POST /candidate` exchanges ICE candidates. DataChannel requests are JSON envelopes containing `id`, `tool`, and `args`, and responses correlate the same `id` with `result`.

The built-in peer uses `webrtc-ruby` and `libdatachannel`. For another native stack, pass `peer_factory:` to `UTCP::WebRTCProtocol`; the adapter contract is demonstrated by the protocol tests.

The built-in peer tracks only pending request IDs and discards unsolicited, duplicate, and late responses. `max_pending_requests` defaults to 1,024. Closing a peer wakes pending callers and serializes native destruction with connection setup and sends. UTCP uses local FFI bindings that release Ruby's GVL during native destruction, allowing outstanding callbacks to finish; it does not alter the installed gem's bindings.

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

Manual-specific names are tried first. For a manual named `weather_api`, `${TOKEN}` first looks for `weather__api_TOKEN`, then `TOKEN`. Use `get_required_variables_for_manual_and_tools` or `get_required_variables_for_registered_tool` to inspect requirements without exposing values. Discovery performed by the former uses a temporary client and closes its sessions before returning, including on failure; existing client sessions stay open.

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

The 30 MiB (31,457,280 bytes) value budget is shared across strings, numeric payloads, and hash keys within each tool argument, result, or collected stream. String and symbol keys count toward both the byte budget and the 10,000-value limit. Streams are checked one item at a time and stop as soon as the shared budget is exceeded. Integer powers and products are checked before allocating their results, and non-finite floating-point results are rejected. Power checks use a conservative size estimate and can reject expressions close to the limit. Source code is limited to 64 KiB and captured logs to 1 MiB per execution.

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
bundle install
bundle exec rake test
bundle exec rake coverage
bundle exec make standard-demo
gem build ruby-utcp.gemspec
```

CI runs the tests and gem build on Ruby 2.6, 2.7, 3.0–3.4, and 4.0. A separate Ruby 3.4 job runs the local transport examples and enforces minimum coverage of 80% of executable lines and 60% of branches. The standard demo uses WEBrick, included as a development dependency.

A dedicated Ruby 3.4 CI job sets `UTCP_NATIVE_TESTS=1` to install the original, unmodified backends from the Gemfile, builds libdatachannel 0.24.5 and the WebRTC extension, and runs `bundle exec rake native`. The test subprocess has a 45-second watchdog. The native dependencies remain optional for applications using the gem.

The default native suite checks discovery, real calls, response limits, streaming, concurrent requests, timeouts, and client isolation. It also checks the UTCP WebRTC adapter's destruction during an active callback, cancellation of pending calls, and reuse after late responses. Additional probes of the upstream backend itself are opt-in with `UTCP_WEBRTC_SHUTDOWN_REGRESSIONS=1`; they require callback shutdown guarantees that stock `webrtc-ruby` 1.0.0 bindings do not provide and are not part of the CI job. No patches are installed into the dependency.

### Sustained load and memory checks

```sh
bundle exec rake 'soak[http]'
# Requires the same built native dependencies as the native CI job:
UTCP_NATIVE_TESTS=1 bundle exec rake 'soak[webrtc]'
```

Local commands default to five minutes per scenario with eight concurrent callers. HTTP mixes SSE and NDJSON, complete reads, early enumeration exits, and oversized responses. WebRTC creates real peer pairs, checks concurrent response correlation, times out a late reply, verifies the next request, and closes a peer with a pending call from multiple threads. Both ends and fixture queues are reclaimed between WebRTC cycles. Missing native dependencies fail the command; they are never silently skipped or automatically downloaded.

Reports are written to `tmp/soak/http.json` and `tmp/soak/webrtc.json`. They contain operation counts, configuration, Ruby/platform details, and resource samples taken at quiet batch boundaries after full GC. Measurements cover both the client and its local test server in one process: RSS, retained Ruby heap bytes, live Ruby objects, Ruby threads, and file descriptors. The first post-warmup sample is the baseline. Any later sample exceeding a growth limit fails the run, even if memory subsequently falls. These are sampled, post-GC measurements, not a continuous peak-RSS measurement or proof that no leak can occur in a longer or different workload.

| Environment variable | Local default |
| --- | --- |
| `UTCP_SOAK_DURATION` | 300 seconds, including warmup |
| `UTCP_SOAK_WARMUP` | 30 seconds |
| `UTCP_SOAK_INTERVAL` | 10 seconds |
| `UTCP_SOAK_CONCURRENCY` | 8, allowed range 1–64 |
| `UTCP_SOAK_REQUESTS_PER_SECOND` | 200; `0` disables pacing |
| `UTCP_SOAK_RSS_GROWTH_MIB` | 32 MiB |
| `UTCP_SOAK_HEAP_GROWTH_MIB` | 8 MiB |
| `UTCP_SOAK_OBJECT_GROWTH` | 20,000 objects |
| `UTCP_SOAK_THREAD_GROWTH` | 4 threads |
| `UTCP_SOAK_FD_GROWTH` | 4 descriptors |
| `UTCP_SOAK_REPORT` | `tmp/soak/<scenario>.json` |

Pacing prevents a connection-churn test from exhausting a CI host's ephemeral TCP ports. Increase duration for a longer run, for example `UTCP_SOAK_DURATION=1800 bundle exec rake 'soak[http]'`. Duration must allow warmup and at least three sample intervals. A parent-process watchdog allows an additional 60 seconds for setup and cleanup, then kills a stuck subprocess and records failure. Reports are checkpointed during the run, and failed subprocesses cannot reuse a stale passing report.

On pushes and pull requests, CI runs each soak for 60 seconds, including a 10-second warmup. Full five-minute runs with a 30-second warmup are available only through manual dispatch: **Actions → CI → Run workflow**. Both modes sample every 10 seconds. The HTTP soak runs in a separate job and the WebRTC soak follows the native regression suite, using the existing pinned backend build. Both jobs upload their JSON reports as artifacts, including reports from failed runs when available.
