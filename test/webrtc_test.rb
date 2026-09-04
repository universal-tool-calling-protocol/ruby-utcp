# frozen_string_literal: true

require_relative "test_helper"

class WebRTCProtocolTest < Minitest::Test
  class Peer
    attr_reader :identifier, :closed

    def initialize(identifier, failure: nil)
      @identifier = identifier
      @failure = failure
    end

    def connect
      raise @failure if @failure
      { "tools" => [{ "name" => "echo" }] }
    end

    def request(payload, timeout:)
      raise IOError, "peer closed" if @closed
      { "peer" => identifier, "args" => payload.fetch("args") }
    end

    def close
      @closed = true
    end
  end

  def setup
    @original = UTCP.protocol("webrtc")
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    UTCP.register_protocol("webrtc", @original)
  end

  def new_client
    UTCP::Client.create(config: { manual_call_templates: [{
      name: "rtc", call_template_type: "webrtc", signaling_server: "http://localhost:12345",
      peer_id: "same-name", data_channel_name: "tools"
    }] }).tap { |client| @clients << client }
  end

  def test_clients_with_identical_templates_own_separate_peers
    peers = []
    UTCP.register_protocol("webrtc", UTCP::WebRTCProtocol.new(peer_factory: ->(_template) { Peer.new(peers.length).tap { |peer| peers << peer } }))
    first = new_client
    second = new_client
    assert_equal 0, first.call_tool("rtc.echo")["peer"]
    assert_equal 1, second.call_tool("rtc.echo")["peer"]
    first.close
    assert peers.first.closed
    refute peers.last.closed
    assert_equal({ "peer" => 1, "args" => { "message" => "after close" } }, second.call_tool("rtc.echo", message: "after close"))
  end

  def test_failed_registration_closes_and_removes_the_peer
    peer = Peer.new(1, failure: UTCP::TimeoutError.new("connection failed"))
    UTCP.register_protocol("webrtc", UTCP::WebRTCProtocol.new(peer_factory: ->(_template) { peer }))
    client = new_client
    refute client.registration_results.first.success?
    assert peer.closed
    assert_empty client.list_tools
  end

  def test_parallel_calls_use_one_peer_and_keep_arguments_separate
    count = 0
    UTCP.register_protocol("webrtc", UTCP::WebRTCProtocol.new(peer_factory: ->(_template) { count += 1; Peer.new(count) }))
    client = new_client
    workers = 8.times.map { |index| Thread.new { client.call_tool("rtc.echo", index: index) } }
    workers.each_with_index do |worker, index|
      assert worker.join(3), "WebRTC worker did not finish"
      assert_equal({ "peer" => 1, "args" => { "index" => index } }, worker.value)
    end
    assert_equal 1, count
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end

  def test_invalid_templates_and_unexpected_backend_errors_are_reported
    protocol = UTCP::WebRTCProtocol.new
    assert_raises(UTCP::ValidationError) { protocol.call_tool(nil, "wrong", {}, UTCP::TextCallTemplate.new(content: "x")) }
    peer = Peer.new(1)
    peer.close
    UTCP.register_protocol("webrtc", UTCP::WebRTCProtocol.new(peer_factory: ->(_template) { peer }))
    client = new_client
    error = assert_raises(UTCP::ToolCallError) { client.call_tool("rtc.echo") }
    assert_equal "rtc.echo", error.tool_name
    assert_match(/peer closed/, error.message)
  end
end
