# frozen_string_literal: true

require "utcp"

# GET /utcp must return a UTCP 1.1 manual. Tool URLs are taken from that manual.
client = UTCP::Client.create(config: {
  variables: { API_TOKEN: ENV.fetch("API_TOKEN", "development-token") },
  manual_call_templates: [{
    name: "rest",
    call_template_type: "http",
    url: ENV.fetch("UTCP_HTTP_MANUAL", "http://localhost:8080/utcp"),
    http_method: "GET"
  }]
})

puts client.list_tools.map(&:name)
puts client.call_tool("rest.echo", body: { message: "Hello over HTTP" }).inspect
