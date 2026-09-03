# Transport examples

Each official transport has a client example. Network transports include a matching local server under `examples/servers`:

| Transport | Client | Matching server |
| --- | --- | --- |
| HTTP | `http.rb` | `servers/http_server.rb` |
| SSE | `sse.rb` | `servers/sse_server.rb` |
| Streamable HTTP | `streamable_http.rb` | `servers/streamable_http_server.rb` |
| CLI | `cli.rb` | self-contained |
| WebSocket | `websocket.rb` | `servers/websocket_server.rb` |
| gRPC | `grpc.rb`, `grpc_python.py` | `servers/grpc_server.rb` or `servers/grpc_server.py` |
| GraphQL | `graphql.rb` | `servers/graphql_server.rb` |
| TCP | `tcp.rb` | `servers/tcp_server.rb` |
| UDP | `udp.rb` | `servers/udp_server.rb` |
| WebRTC | `webrtc.rb` | `servers/webrtc_server.rb` |
| MCP | `mcp.rb` | `servers/mcp_stdio_server.rb`, launched by the client |
| Text | `text.rb` | self-contained |

For a network example, start the server in one terminal and the client in another:

```sh
ruby -Ilib examples/servers/http_server.rb
ruby -Ilib examples/http.rb
```

Replace `http` with `sse`, `streamable_http`, `websocket`, `graphql`, `tcp`, or `udp` for the other standard-library pairs. The MCP client starts its stdio server automatically. CLI and text run without a server:

```sh
ruby -Ilib examples/cli.rb
ruby -Ilib examples/text.rb
```

The HTTP-family and GraphQL servers use WEBrick. On Ruby versions where it is not bundled, add `gem "webrick"`. The gRPC pair additionally needs `gem "grpc"`. The WebRTC pair needs Ruby 3.1+, `gem "webrtc-ruby"`, and a working `libdatachannel` installation.

The Python server and client import the checked-in `utcp_pb2.py` and `utcp_pb2_grpc.py` stubs from `examples/generated`. Regenerate both files from [`proto/utcp.proto`](../proto/utcp.proto) with `protoc` after changing the contract:

```sh
make grpc-python-setup    # create .venv-grpc, install dependencies, generate stubs
make grpc-python-generate # regenerate stubs with grpc_tools.protoc
make grpc-python-server  # server only, on 127.0.0.1:50051
make grpc-python-client  # generated-stub Python client; server must be running
make grpc-python-demo    # start server, run Ruby + Python clients, stop server
```

All servers bind only to `127.0.0.1`. Set `PORT` on a server and the corresponding `UTCP_*` environment variable on its client to change an endpoint.

To run everything together, use the repository `Makefile`:

```sh
make                 # run every available pair; report and skip missing optional backends
make full-demo       # require dependencies, then run all 12 examples
make servers         # keep every available network server running until Ctrl-C
make full-servers    # require dependencies, then keep every server running
make examples        # run available clients against servers that are already running
make full-examples   # require dependencies, then run all 12 clients
make standard-demo   # skip native gRPC and WebRTC pairs
make grpc-python-demo # run the Ruby client against the Python gRPC server
make test
```

`make`, `make servers`, and `make examples` detect gRPC and WebRTC independently. If an optional backend is absent, they skip only that pair. The `full-*` targets fail early with an installation hint unless all dependencies are available. WebRTC requires Ruby 3.1+.
