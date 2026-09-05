# Changelog

## Unreleased

- Raise the Code Mode value budget to 30 MiB, account for string/symbol hash keys, and enforce shared byte, item, and step limits while collecting streams.
- Close temporary discovery sessions when inspecting required variables, preserving active MCP, WebRTC, and WebSocket sessions. Isolate persistent WebSocket connections between clients and close transient discovery sockets on failure.
- Run real gRPC/WebRTC tests in CI using pinned, unmodified native dependencies and libdatachannel 0.24.5. Keep the additional backend shutdown probes opt-in rather than requiring modified WebRTC bindings.
- Correct the README coverage thresholds and document the native integration setup.

## 1.1.3

- Split Code Mode into focused components while preserving the public API; fix `do...end` block results.
- Add branch-focused interpreter tests, concurrent request tests, and local HTTP/TCP/WebSocket fault injection.
- Isolate WebRTC peers between clients, close failed registrations, and align native offer/answer negotiation with `webrtc-ruby`.
- Close WebSocket sockets when the opening handshake fails.
- Add an opt-in real gRPC/WebRTC integration suite and raise coverage gates to 80% lines / 60% branches.
- Bound native integration runs with a subprocess watchdog and add real callback/concurrent-shutdown regression tests for the locally patched WebRTC backend.

## 1.1.2

- Isolate MCP sessions and resource mappings between clients and clean up failed registrations.
- Follow MCP tool/resource pagination and raise `ToolCallError` for tool failures, preserving the original payload.
- Enforce stdio deadlines across partial reads, notifications, and blocked writes; bound message and stderr buffers.
- Bound Code Mode integer powers, products, and numeric results, including aggregate tool-result budgets.
- Declare `base64` and `logger` runtime dependencies for Bundler compatibility.
- Add regression tests, coverage checks, a Ruby version CI matrix, and local transport integration checks.

## 1.1.1

- Add Code Mode for composing tools with a constrained Ruby interpreter, progressive tool discovery, captured logs, and execution limits.

## 1.1.0

- Initial Ruby implementation of the UTCP 1.1 client and data model.
- All 12 reference transports: HTTP, SSE, Streamable HTTP, CLI, WebSocket, gRPC,
  GraphQL, TCP, UDP, WebRTC, MCP, and text; plus a Ruby file extension.
- Streaming enumerators, GraphQL introspection/subscriptions, socket framing,
  MCP stdio/HTTP sessions, RFC 6455 WebSockets, and optional native gRPC/WebRTC backends.
- Secure-by-default `allowed_communication_protocols` enforcement.
- Migration helpers for UTCP v0.1 configuration and manuals.
