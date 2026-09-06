# frozen_string_literal: true

require_relative "test_helper"

class WebRTCPeerTest < Minitest::Test
  class Channel
    attr_reader :sent, :closes, :destroys
    attr_accessor :reply, :send_error

    def initialize
      @sent = Queue.new
      @closes = @destroys = 0
    end

    def on_open(&block); @on_open = block; end
    def on_close(&block); @on_close = block; end
    def on_message(&block); @on_message = block; end

    def send_text(message)
      raise send_error if send_error
      payload = JSON.parse(message)
      @sent << payload
      @reply.call(payload) if @reply
    end

    def deliver(value)
      @on_message.call(Struct.new(:data).new(JSON.generate(value)))
    end

    def remote_close
      @on_close.call
    end

    def close
      @closes += 1
      remote_close
    end

    def destroy
      @destroys += 1
    end
  end

  class Connection
    attr_reader :channel, :closes
    def initialize
      @channel = Channel.new
      @closes = 0
    end
    def on_ice_candidate(&block); end
    def create_data_channel(_name); channel; end
    def close; @closes += 1; end
  end

  def setup
    @workers = []
    @connection = Connection.new
    @channel = @connection.channel
    @template = UTCP::WebRtcCallTemplate.new(signaling_server: "http://localhost/", peer_id: "test", data_channel_name: "tools", timeout: 1)
    @peer = UTCP::WebRTCPeer.new(@template, connection: @connection)
  end

  def teardown
    @peer.close
    @workers.each { |worker| worker.kill.join if worker.alive? }
  end

  def worker(id)
    Thread.new do
      @peer.request({ "id" => id }, timeout: 3)
    rescue UTCP::Error => error
      error
    end.tap { |thread| @workers << thread }
  end

  def test_synchronous_responses_are_not_lost_and_duplicates_do_not_replace_results
    @channel.reply = lambda do |payload|
      @channel.deliver("id" => payload["id"], "result" => nil)
      @channel.deliver("id" => payload["id"], "result" => "duplicate")
    end
    assert_nil @peer.request({ "id" => "immediate" })
    assert_empty @peer.instance_variable_get(:@pending)
  end

  def test_timeouts_late_unsolicited_and_malformed_responses_do_not_accumulate
    100.times do |index|
      id = "expired-#{index}"
      assert_raises(UTCP::TimeoutError) { @peer.request({ "id" => id }, timeout: 0.001) }
      @channel.deliver("id" => id, "result" => "late")
      @channel.deliver("id" => "unsolicited-#{index}", "result" => "unknown")
    end
    [nil, [], 1, "text", { "result" => "missing id" }].each { |value| @channel.deliver(value) }
    assert_empty @peer.instance_variable_get(:@pending)
    @channel.reply = ->(payload) { @channel.deliver("id" => payload["id"], "result" => "ok") }
    assert_equal "ok", @peer.request({ "id" => "next" })
  end

  def test_close_wakes_pending_calls_and_is_idempotent_under_concurrency
    16.times { |index| worker("pending-#{index}") }
    16.times { Timeout.timeout(1) { @channel.sent.pop } }
    closers = 8.times.map { Thread.new { @peer.close } }
    closers.each { |thread| assert thread.join(1) }
    @workers.each do |thread|
      assert thread.join(1), "close must wake requests before their timeout"
      assert_instance_of UTCP::ToolCallError, thread.value
      assert_match(/closed/, thread.value.message)
    end
    assert_equal 1, @connection.closes
    assert_equal 1, @channel.closes
    assert_equal 1, @channel.destroys
    assert_raises(UTCP::ToolCallError) { @peer.request({ "id" => "after-close" }) }
    assert_empty @peer.instance_variable_get(:@pending)
  ensure
    closers&.each { |thread| thread.kill.join if thread.alive? }
  end

  def test_remote_close_and_oversized_responses_fail_pending_calls_promptly
    thread = worker("remote")
    Timeout.timeout(1) { @channel.sent.pop }
    @channel.remote_close
    assert thread.join(1)
    assert_match(/channel closed/, thread.value.message)
  end

  def test_pending_limit_duplicate_ids_send_failure_and_response_size_limit
    @template.max_pending_requests = 1
    thread = worker("one")
    Timeout.timeout(1) { @channel.sent.pop }
    assert_raises(UTCP::ValidationError) { @peer.request({ "id" => "one" }) }
    assert_raises(UTCP::ToolCallError) { @peer.request({ "id" => "two" }) }
    @channel.deliver("id" => "one", "result" => true)
    assert thread.join(1)
    assert_equal true, thread.value
    @channel.send_error = IOError.new("failed write")
    assert_raises(IOError) { @peer.request({ "id" => "write" }) }
    assert_empty @peer.instance_variable_get(:@pending)
    @channel.send_error = nil
    @template.max_response_bytes = 32
    @channel.reply = ->(payload) { @channel.deliver("id" => payload["id"], "result" => "x" * 100) }
    error = assert_raises(UTCP::ToolCallError) { @peer.request({ "id" => "large" }) }
    assert_match(/max_response_bytes/, error.message)
    assert_empty @peer.instance_variable_get(:@pending)
  end

  def test_out_of_order_parallel_responses_remain_correlated
    32.times { |index| worker(index.to_s) }
    requests = 32.times.map { Timeout.timeout(1) { @channel.sent.pop } }
    requests.reverse_each { |payload| @channel.deliver("id" => payload["id"], "result" => payload["id"]) }
    @workers.each_with_index do |thread, index|
      assert thread.join(1)
      assert_equal index.to_s, thread.value
    end
    assert_empty @peer.instance_variable_get(:@pending)
  end

  def test_response_arriving_after_deadline_during_send_is_discarded
    @channel.reply = lambda do |payload|
      sleep 0.02
      @channel.deliver("id" => payload["id"], "result" => "late")
    end
    assert_raises(UTCP::TimeoutError) { @peer.request({ "id" => "slow-send" }, timeout: 0.001) }
    assert_empty @peer.instance_variable_get(:@pending)
  end

  def test_partial_initialization_releases_the_connection
    connection = Connection.new
    connection.define_singleton_method(:create_data_channel) { |_name| raise IOError, "channel failed" }
    assert_raises(IOError) { UTCP::WebRTCPeer.new(@template, connection: connection) }
    assert_equal 1, connection.closes
  end
end
