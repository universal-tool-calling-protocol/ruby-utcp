# frozen_string_literal: true

require_relative "http_helpers"

port = Integer(ENV.fetch("PORT", "8080"))
base = "http://localhost:#{port}"

ExampleHTTP.server(port) do |server|
  server.mount_proc("/utcp") do |_request, response|
    ExampleHTTP.json(response, {
      utcp_version: "1.1.0",
      manual_version: "1.0.0",
      tools: [{
        name: "echo",
        tool_call_template: {
          call_template_type: "http",
          url: "#{base}/echo",
          http_method: "POST",
          body_field: "body"
        }
      }]
    })
  end

  server.mount_proc("/echo") do |request, response|
    ExampleHTTP.json(response, ExampleHTTP.request_json(request))
  end
end
