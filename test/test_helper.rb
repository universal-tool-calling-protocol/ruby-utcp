# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "utcp"

class FakeHTTPResponse
  attr_reader :code, :body

  def initialize(code: 200, body: "", headers: {})
    @code = code.to_s
    @body = body
    @headers = headers.each_with_object({}) { |(key, value), values| values[key.downcase] = value }
  end

  def [](name)
    @headers[name.downcase]
  end
end

class FakeStreamingResponse < FakeHTTPResponse
  def initialize(chunks:, code: 200, headers: {})
    super(code: code, body: chunks.join, headers: headers)
    @chunks = chunks
  end

  def read_body
    @chunks.each { |chunk| yield chunk }
  end
end

class FakeHTTPProtocol < UTCP::HTTPProtocol
  attr_reader :requests

  def initialize(&handler)
    super()
    @handler = handler
    @requests = []
  end

  private

  def send_request(uri, request, timeout)
    details = {
      method: request.method,
      target: uri.request_uri,
      headers: request.each_header.to_h,
      body: request.body,
      timeout: timeout
    }
    requests << details
    @handler.call(details)
  end
end
