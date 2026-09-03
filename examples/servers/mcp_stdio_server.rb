# frozen_string_literal: true

require "json"

$stdout.sync = true

ARGF.each_line do |line|
  message = JSON.parse(line)
  next unless message.key?("id")

  result = case message["method"]
           when "initialize"
             {
               protocolVersion: message.dig("params", "protocolVersion") || "2025-06-18",
               capabilities: { tools: {}, resources: {} },
               serverInfo: { name: "ruby-example", version: "1.0.0" }
             }
           when "tools/list"
             {
               tools: [{
                 name: "echo",
                 description: "Echo a message",
                 inputSchema: {
                   type: "object",
                   properties: { message: { type: "string" } },
                   required: ["message"]
                 }
               }]
             }
           when "tools/call"
             text = message.dig("params", "arguments", "message").to_s
             { content: [{ type: "text", text: JSON.generate(echo: text) }] }
           when "resources/list"
             { resources: [{ name: "welcome", uri: "memory://welcome", description: "Welcome text" }] }
           when "resources/read"
             { contents: [{ uri: "memory://welcome", mimeType: "text/plain", text: "Hello from MCP" }] }
           else
             {}
           end
  puts JSON.generate(jsonrpc: "2.0", id: message["id"], result: result)
rescue JSON::ParserError => error
  warn error.message
end
