# frozen_string_literal: true

require "json"
require "webrick"

module ExampleHTTP
  module_function

  def server(port)
    instance = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: port,
      AccessLog: [],
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
    )
    trap("INT") { instance.shutdown }
    trap("TERM") { instance.shutdown }
    yield instance
    warn "Listening on http://127.0.0.1:#{port}"
    instance.start
  end

  def json(response, value, status: 200)
    response.status = status
    response["Content-Type"] = "application/json"
    response.body = JSON.generate(value)
  end

  def request_json(request)
    request.body.to_s.empty? ? {} : JSON.parse(request.body)
  rescue JSON::ParserError
    {}
  end
end
