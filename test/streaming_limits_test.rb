# frozen_string_literal: true

require_relative "test_helper"

class StreamingLimitsTest < Minitest::Test
  def events(chunks, **options)
    values = []
    parser = UTCP::SSEParser.new(**options)
    chunks.each { |chunk| parser.feed(chunk) { |value| values << value } }
    parser.finish
    values
  end

  def test_sse_is_independent_of_every_byte_boundary_including_crlf_bom_and_utf8
    ["\n", "\r", "\r\n"].each do |ending|
      wire = ("\uFEFF: comment#{ending}event: update#{ending}data: {\"ok\":#{ending}" \
              "data: \"zażółć\"}#{ending}#{ending}data:#{ending}#{ending}").b
      expected = [{ "ok" => "zażółć" }, ""]
      (0..wire.bytesize).each do |split|
        assert_equal expected, events([wire.byteslice(0, split), wire.byteslice(split, wire.bytesize)])
      end
      assert_equal expected, events(wire.bytes.map { |byte| byte.chr })
    end
  end

  def test_sse_random_chunking_multiline_data_filtering_and_incomplete_eof
    wire = ("event: skip\r\ndata: no\r\n\r\nevent: ok\r\ndata: first\r\ndata: second\r\n\r\n" * 20).b
    random = Random.new(12_345)
    30.times do
      chunks = []
      offset = 0
      while offset < wire.bytesize
        length = random.rand(1..31)
        chunks << wire.byteslice(offset, length)
        offset += length
      end
      assert_equal ["first\nsecond"] * 20, events(chunks, event_type: "ok")
    end
    assert_empty events(["data: unfinished\n"])
    assert_empty events(["data: unfinished"])
  end

  def test_sse_limits_unterminated_lines_and_aggregate_multiline_events
    assert_raises(UTCP::ToolCallError) { events(["data: ", "x" * 100], max_event_bytes: 20) }
    assert_raises(UTCP::ToolCallError) { events(["data: x\n" * 10], max_event_bytes: 20) }
    assert_equal ["x"] * 50, events(["data: x\n\n" * 50], max_event_bytes: 7)
  end

  def test_consumer_json_errors_are_not_swallowed_or_delivered_twice
    parser = UTCP::SSEParser.new
    count = 0
    assert_raises(JSON::ParserError) do
      parser.feed("data: 1\n\n") { count += 1; raise JSON::ParserError, "consumer error" }
    end
    assert_equal 1, count
  end

  def protocol_for(type, chunks, content_type:, status: 200)
    klass = type == :sse ? UTCP::SSEProtocol : UTCP::StreamableHTTPProtocol
    protocol = klass.new
    @read_chunks = 0
    response = FakeStreamingResponse.new(chunks: [], code: status, headers: { "Content-Type" => content_type })
    owner = self
    response.define_singleton_method(:read_body) do |&block|
      chunks.each do |chunk|
        owner.instance_variable_set(:@read_chunks, owner.instance_variable_get(:@read_chunks) + 1)
        block.call(chunk)
      end
    end
    protocol.define_singleton_method(:send_stream_request) do |_uri, _request, _timeout, &block|
      begin
        block.call(response)
      ensure
        owner.instance_variable_set(:@stream_closed, true)
      end
    end
    protocol
  end

  def stream_template(**options)
    UTCP::StreamableHttpCallTemplate.new(url: "http://localhost/", **options)
  end

  def test_ndjson_and_json_sequence_at_every_byte_boundary
    { "application/x-ndjson" => "{\"x\":\"ż\"}\n{\"x\":2}\n",
      "application/json-seq" => "\x1E{\n\"x\":\"ż\"\n}\n\x1E{\"x\":2}\n" }.each do |content_type, wire|
      wire = wire.b
      (0..wire.bytesize).each do |split|
        protocol = protocol_for(:stream, [wire.byteslice(0, split), wire.byteslice(split, wire.bytesize)], content_type: content_type)
        assert_equal [{ "x" => "ż" }, { "x" => 2 }], protocol.call_tool(nil, "test", {}, stream_template)
      end
    end
  end

  def test_response_event_and_item_limits_stop_consumption_and_close_streams
    ["application/x-ndjson", "application/json-seq", "application/json"].each do |content_type|
      protocol = protocol_for(:stream, [" " * 15, " " * 15, "unread"], content_type: content_type)
      error = assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, stream_template(max_event_bytes: 20)) }
      assert_match(/max_event_bytes/, error.message)
      assert_equal 2, @read_chunks
      assert @stream_closed
    end
    protocol = protocol_for(:stream, ["1234", "5678", "unread"], content_type: "application/octet-stream")
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, stream_template(max_response_bytes: 7)) }
    assert_equal 2, @read_chunks
    protocol = protocol_for(:stream, Array.new(100, "1\n"), content_type: "application/x-ndjson")
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, stream_template(max_response_items: 3)) }
    assert_equal 4, @read_chunks
    protocol = protocol_for(:sse, Array.new(100, "data: 1\n\n"), content_type: "text/event-stream")
    template = UTCP::SseCallTemplate.new(url: "http://localhost/", max_response_items: 3)
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, template) }
    assert_equal 4, @read_chunks
  end

  def test_error_response_bodies_are_also_bounded
    protocol = protocol_for(:stream, ["x" * 8, "y" * 8, "unread"], content_type: "text/plain", status: 500)
    assert_raises(UTCP::ToolCallError) { protocol.call_tool(nil, "test", {}, stream_template(max_response_bytes: 10)) }
    assert_equal 2, @read_chunks
    assert @stream_closed
  end

  def test_breaking_enumeration_closes_the_response_without_reading_the_remainder
    protocol = protocol_for(:stream, ["1\n", "2\n"], content_type: "application/x-ndjson")
    protocol.call_tool_streaming(nil, "test", {}, stream_template).each { |value| break if value == 1 }
    assert @stream_closed
    assert_equal 1, @read_chunks
  end

  def test_limits_are_validated_and_survive_template_serialization
    [UTCP::HttpCallTemplate, UTCP::SseCallTemplate, UTCP::StreamableHttpCallTemplate].each do |klass|
      template = klass.new(url: "http://localhost/", max_response_bytes: 30, max_event_bytes: 12, max_response_items: 4, total_timeout: 0.2)
      assert_equal template.to_h, UTCP::CallTemplate.from_h(template.to_h).to_h
      %i[max_response_bytes max_event_bytes max_response_items total_timeout].each do |name|
        assert_raises(UTCP::ValidationError) { klass.new(url: "http://localhost/", **{ name => 0 }) }
      end
      assert_raises(UTCP::ValidationError) { klass.new(url: "http://localhost/", total_timeout: Float::INFINITY) }
    end
  end
end
