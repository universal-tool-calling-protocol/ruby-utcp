# Changelog

## 1.1.0

- Initial Ruby implementation of the UTCP 1.1 client and data model.
- All 12 reference transports: HTTP, SSE, Streamable HTTP, CLI, WebSocket, gRPC,
  GraphQL, TCP, UDP, WebRTC, MCP, and text; plus a Ruby file extension.
- Streaming enumerators, GraphQL introspection/subscriptions, socket framing,
  MCP stdio/HTTP sessions, RFC 6455 WebSockets, and optional native gRPC/WebRTC backends.
- Secure-by-default `allowed_communication_protocols` enforcement.
- Migration helpers for UTCP v0.1 configuration and manuals.
