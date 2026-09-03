# frozen_string_literal: true

require_relative "http_helpers"

port = Integer(ENV.fetch("PORT", "8082"))
base = "http://localhost:#{port}"

ExampleHTTP.server(port) do |server|
  server.mount_proc("/utcp") do |_request, response|
    ExampleHTTP.json(response, {
      utcp_version: "1.1.0",
      tools: [{
        name: "tokens",
        tool_call_template: {
          call_template_type: "streamable_http",
          url: "#{base}/tokens",
          http_method: "POST",
          content_type: "application/json",
          body_field: "body",
          chunk_size: 32,
          timeout: 60_000
        }
      }]
    })
  end

  server.mount_proc("/tokens") do |request, response|
    prompt = ExampleHTTP.request_json(request)["prompt"].to_s
    response.status = 200
    response["Content-Type"] = "application/x-ndjson"
    response.chunked = true
    response.body = proc do |output|
      prompt.split.each_with_index do |token, index|
        output.write(JSON.generate(index: index, token: token) + "\n")
        sleep 0.15
      end
    end
  end
end
