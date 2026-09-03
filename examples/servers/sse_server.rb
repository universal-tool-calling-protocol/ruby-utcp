# frozen_string_literal: true

require_relative "http_helpers"

port = Integer(ENV.fetch("PORT", "8081"))
base = "http://localhost:#{port}"

ExampleHTTP.server(port) do |server|
  server.mount_proc("/utcp") do |_request, response|
    ExampleHTTP.json(response, {
      utcp_version: "1.1.0",
      tools: [{
        name: "watch",
        tool_call_template: {
          call_template_type: "sse",
          url: "#{base}/watch",
          event_type: "update"
        }
      }]
    })
  end

  server.mount_proc("/watch") do |request, response|
    topic = request.query["topic"] || "events"
    response.status = 200
    response["Content-Type"] = "text/event-stream"
    response["Cache-Control"] = "no-cache"
    response.chunked = true
    response.body = proc do |output|
      3.times do |index|
        output.write("id: #{index + 1}\nevent: update\ndata: #{JSON.generate(topic: topic, number: index + 1)}\n\n")
        sleep 0.2
      end
    end
  end
end
