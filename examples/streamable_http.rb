# frozen_string_literal: true

require "utcp"

# Supports NDJSON, JSON Sequence, JSON, and arbitrary binary chunks.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "generator",
    call_template_type: "streamable_http",
    url: ENV.fetch("UTCP_STREAM_MANUAL", "http://localhost:8082/utcp"),
    http_method: "GET",
    chunk_size: 4096,
    timeout: 60_000
  }]
})

client.call_tool_streaming("generator.tokens", body: { prompt: "Hello from Ruby" }) { |chunk| puts chunk.inspect }
