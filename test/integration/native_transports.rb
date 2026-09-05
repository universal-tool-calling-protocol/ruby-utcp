# frozen_string_literal: true

# Deliberately outside *_test.rb: this suite requires real, loadable native gems.
require_relative "../test_helper"
require "grpc"
gem "webrtc-ruby", "1.0.0"
require "webrtc"
require "webrick"
require "timeout"

class NativeMessage
  attr_reader :bytes

  def initialize(bytes = "".b)
    @bytes = bytes
  end

  def self.encode(message)
    message.bytes
  end

  def self.decode(bytes)
    new(bytes)
  end
end

class NativeService
  include GRPC::GenericService
  self.marshal_class_method = :encode
  self.unmarshal_class_method = :decode
  self.service_name = "grpcpb.UTCPService"
  rpc :GetManual, NativeMessage, NativeMessage
  rpc :CallTool, NativeMessage, NativeMessage
  rpc :CallToolStream, NativeMessage, stream(NativeMessage)

  def get_manual(_request, _call)
    tool = UTCP::ProtobufWire.string_field(1, "echo") + UTCP::ProtobufWire.string_field(2, "Native echo")
    NativeMessage.new(UTCP::ProtobufWire.string_field(1, "1.0.0") + UTCP::ProtobufWire.string_field(2, tool))
  end

  def call_tool(request, call)
    args = JSON.parse(UTCP::ProtobufWire.fields(request.bytes)[2].first)
    raise GRPC::Unavailable, "simulated outage" if args["fail"]
    sleep 0.2 if args["slow"]
    NativeMessage.new(UTCP::ProtobufWire.string_field(1, JSON.generate(args.merge("authorization" => call.metadata["authorization"]))))
  end

  def call_tool_stream(request, call)
    response = call_tool(request, call)
    [response, response].each
  end
end

class NativeGRPCTest < Minitest::Test
  def setup
    @server = GRPC::RpcServer.new
    @port = @server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
    @server.handle(NativeService.new)
    @worker = Thread.new { @server.run }
    raise "gRPC server did not start" unless @server.wait_till_running(5)
    @client = UTCP::Client.create(config: { manual_call_templates: [{
      name: "native", call_template_type: "grpc", host: "127.0.0.1", port: @port, use_ssl: false,
      auth: { auth_type: "basic", username: "tester", password: "test-only" }
    }] })
  end

  def teardown
    @client&.close
    @server.stop if @server&.running?
    @worker.kill if @worker && !@worker.join(3)
  end

  def test_real_discovery_unary_streaming_and_metadata
    assert @client.registration_results.first.success?
    assert_equal ["native.echo"], @client.list_tools.map(&:name)
    result = @client.call_tool("native.echo", message: "zażółć")
    assert_equal "zażółć", result["message"]
    assert_equal "Basic #{Base64.strict_encode64('tester:test-only')}", result["authorization"]
    assert_equal 2, @client.call_tool_streaming("native.echo", message: "stream").to_a.length
  end

  def test_real_parallel_calls_do_not_mix_results
    workers = 6.times.map { |index| Thread.new { @client.call_tool("native.echo", index: index) } }
    workers.each_with_index do |worker, index|
      assert worker.join(3), "gRPC worker did not finish"
      assert_equal index, worker.value["index"]
    end
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end

  def test_real_deadline_and_remote_failure
    error = assert_raises(UTCP::ToolCallError) { @client.call_tool("native.echo", fail: true) }
    assert_match(/simulated outage/, error.message)
    template = UTCP::GrpcCallTemplate.new(host: "127.0.0.1", port: @port, timeout: 0.05, use_ssl: false)
    error = assert_raises(UTCP::ToolCallError) { UTCP::GRPCProtocol.new.call_tool(nil, "echo", { slow: true }, template) }
    assert_match(/deadline/i, error.message)
  end
end

class NativeWebRTCTest < Minitest::Test
  def setup
    WebRTC.init
    @peers = []
    @peers_by_id = {}
    @channels = []
    @clients = []
    @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, AccessLog: [],
                                    Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL))
    @server.mount_proc("/connect") { |request, response| connect_peer(request, response) }
    @server.mount_proc("/candidate") do |request, response|
      payload = JSON.parse(request.body)
      peer = @peers_by_id.fetch(payload.fetch("peer_id"))
      peer.add_ice_candidate(WebRTC::RTCIceCandidate.new(UTCP::Utils.symbolize_keys(payload.fetch("candidate")))).await
      response["Content-Type"] = "application/json"
      response.body = "{}"
    end
    started = Queue.new
    @server.config[:StartCallback] = -> { started << true }
    @worker = Thread.new { @server.start }
    Timeout.timeout(5) { started.pop }
  end

  def teardown
    @clients.each(&:close)
    @server&.shutdown
    @worker.kill if @worker && !@worker.join(3)
    @channels.each { |channel| channel.close; channel.destroy }
    @peers.each(&:close)
  end

  def connect_peer(request, response)
    payload = JSON.parse(request.body)
    peer = WebRTC::RTCPeerConnection.new({ disable_auto_negotiation: true })
    @peers << peer
    @peers_by_id[payload.fetch("peer_id")] = peer
    candidates = []
    peer.on_ice_candidate { |candidate| candidates << candidate if candidate }
    peer.on_data_channel do |channel|
      @channels << channel
      channel.on_message do |message|
        envelope = JSON.parse(message.data)
        next if envelope.dig("args", "no_response")
        channel.send_text(JSON.generate(id: envelope["id"], result: envelope["args"]))
      end
    end
    peer.set_remote_description(WebRTC::RTCSessionDescription.new(type: :offer, sdp: payload.fetch("sdp"))).await
    answer = peer.create_answer.await
    mutex = Mutex.new
    condition = ConditionVariable.new
    peer.on_ice_gathering_state_change { mutex.synchronize { condition.broadcast } }
    Timeout.timeout(5) do
      mutex.synchronize { condition.wait(mutex, 0.05) until peer.ice_gathering_state == :complete }
    end
    response["Content-Type"] = "application/json"
    response.body = JSON.generate(sdp: answer.sdp, candidates: candidates.map(&:to_h),
                                  tools: [{ name: "echo", description: "Native data channel echo" }])
  rescue StandardError => error
    response.status = 500
    response.body = JSON.generate(error: error.message)
  end

  def new_client
    client = UTCP::Client.create(config: { manual_call_templates: [{
      name: "native", call_template_type: "webrtc", signaling_server: "http://127.0.0.1:#{@server.config[:Port]}",
      peer_id: "integration", data_channel_name: "tools", timeout: 3
    }] })
    @clients << client
    assert client.registration_results.first.success?, client.registration_results.first.errors.join("; ")
    client
  end

  def test_real_data_channel_roundtrip_and_parallel_correlation
    client = new_client
    assert_equal({ "message" => "zażółć" }, client.call_tool("native.echo", message: "zażółć"))
    workers = 6.times.map { |index| Thread.new { client.call_tool("native.echo", index: index) } }
    workers.each_with_index do |worker, index|
      assert worker.join(4), "WebRTC worker did not finish"
      assert_equal index, worker.value["index"]
    end
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end

  def test_closing_one_client_does_not_break_another
    first = new_client
    second = new_client
    first.close
    assert_equal({ "message" => "still connected" }, second.call_tool("native.echo", message: "still connected"))
  end

  def test_real_missing_response_times_out_then_session_remains_usable
    client = new_client
    assert_raises(UTCP::TimeoutError) { client.call_tool("native.echo", no_response: true) }
    assert_equal({ "message" => "after timeout" }, client.call_tool("native.echo", message: "after timeout"))
  end
end

# Extra backend regression probes require shutdown guarantees absent from the
# stock webrtc-ruby 1.0.0 release. Keep them available without requiring a patch
# for the transport integration suite or modifying the installed dependency.
module NativeWebRTCShutdownRegressions

  def test_channel_destroy_allows_an_active_native_callback_to_finish
    assert_channel_shutdown_progress(:destroy)
  end

  def test_channel_close_allows_an_active_native_callback_to_finish
    assert_channel_shutdown_progress(:close)
  end

  def test_peer_close_allows_an_active_native_callback_to_finish
    entered = Queue.new
    release = Queue.new
    peer = WebRTC::RTCPeerConnection.new({ disable_auto_negotiation: true })
    @peers << peer
    peer.on_ice_gathering_state_change do |state|
      next unless state == :gathering
      entered << true
      release.pop
    end
    @channels << peer.create_data_channel("shutdown")
    peer.create_offer.await
    Timeout.timeout(5) { entered.pop }
    assert_shutdown_releases_ruby(peer, :close, release) do
      assert peer.closed?, "peer must detach its handle before native destruction"
      assert_nil peer.close, "repeated close must not destroy the same handle again"
    end
    assert peer.closed?
  ensure
    release << true if release
  end

  def test_destroy_waits_for_an_in_flight_close_and_frees_the_handle_once
    peer = WebRTC::RTCPeerConnection.new({ disable_auto_negotiation: true })
    @peers << peer
    channel = peer.create_data_channel("close-race")
    @channels << channel
    entered = Queue.new
    release = Queue.new
    events = Queue.new
    close_function = WebRTC::FFI.method(:webrtc_data_channel_close)
    destroy_function = WebRTC::FFI.method(:webrtc_data_channel_destroy)
    WebRTC::FFI.define_singleton_method(:webrtc_data_channel_close) do |ptr|
      entered << true
      release.pop
      close_function.call(ptr)
      events << :close_finished
    end
    WebRTC::FFI.define_singleton_method(:webrtc_data_channel_destroy) do |ptr|
      events << :destroy_started
      destroy_function.call(ptr)
    end

    closer = Thread.new { channel.close }
    Timeout.timeout(5) { entered.pop }
    destroyer = Thread.new { channel.destroy }
    Timeout.timeout(5) { Thread.pass until channel.ready_state == :closed }
    assert events.empty?, "native destruction must wait for the in-flight close"
    assert_nil channel.destroy, "another destroy must not claim the same pointer"
    release << true
    assert closer.join(5), "close did not finish"
    assert destroyer.join(5), "destroy did not finish"
    closer.value
    destroyer.value
    assert_equal [:close_finished, :destroy_started], [events.pop, events.pop]
    assert events.empty?, "native destruction must run exactly once"
  ensure
    release << true if release
    closer&.join(5)
    destroyer&.join(5)
    WebRTC::FFI.define_singleton_method(:webrtc_data_channel_close, close_function) if close_function
    WebRTC::FFI.define_singleton_method(:webrtc_data_channel_destroy, destroy_function) if destroy_function
  end

  def test_channel_rejects_shutdown_from_its_own_callback_without_hanging
    client = new_client
    channel = @channels.fetch(0)
    channel.on_message do |message|
      envelope = JSON.parse(message.data)
      result = begin
        channel.public_send(envelope.fetch("args").fetch("operation"))
        "unexpected success"
      rescue WebRTC::InvalidStateError => error
        error.message
      end
      channel.send_text(JSON.generate(id: envelope["id"], result: result))
    end
    %w[close destroy].each do |operation|
      assert_match(/own callback/, client.call_tool("native.echo", operation: operation))
      assert_equal :open, channel.ready_state
    end
  end

  def test_peer_rejects_shutdown_from_its_own_callback_without_hanging
    result = Queue.new
    peer = WebRTC::RTCPeerConnection.new({ disable_auto_negotiation: true })
    @peers << peer
    peer.on_ice_gathering_state_change do |state|
      next unless state == :gathering
      begin
        peer.close
        result << "unexpected success"
      rescue WebRTC::InvalidStateError => error
        result << error.message
      end
    end
    @channels << peer.create_data_channel("callback-shutdown")
    peer.create_offer.await
    assert_match(/own callback/, Timeout.timeout(5) { result.pop })
    refute peer.closed?
  end

  private

  def assert_channel_shutdown_progress(operation)
    client = new_client
    entered = Queue.new
    release = Queue.new
    channel = @channels.fetch(0)
    channel.on_message do |message|
      envelope = JSON.parse(message.data)
      channel.send_text(JSON.generate(id: envelope["id"], result: envelope["args"]))
      entered << true
      release.pop
    end
    assert_equal({ "message" => "before shutdown" }, client.call_tool("native.echo", message: "before shutdown"))
    Timeout.timeout(5) { entered.pop }
    assert_shutdown_releases_ruby(channel, operation, release) do
      assert_equal :closed, channel.ready_state
      assert_nil channel.destroy if operation == :destroy
    end
    assert_equal :closed, channel.ready_state
  ensure
    release << true if release
  end

  def assert_shutdown_releases_ruby(resource, operation, release)
    worker = Thread.new { resource.public_send(operation) }
    # blocking FFI calls mark the worker as sleeping while native cleanup waits
    # for the callback. Without blocking: true it holds the GVL and even this
    # thread cannot run; rake native's parent-process watchdog catches that.
    Timeout.timeout(5) { Thread.pass while worker.alive? && worker.status != "sleep" }
    assert worker.alive?, "native cleanup returned before its active callback"
    yield if block_given?
    release << true
    assert worker.join(5), "native cleanup did not finish after its callback returned"
    worker.value
  ensure
    release << true
  end
end

NativeWebRTCTest.include(NativeWebRTCShutdownRegressions) if ENV["UTCP_WEBRTC_SHUTDOWN_REGRESSIONS"] == "1"
