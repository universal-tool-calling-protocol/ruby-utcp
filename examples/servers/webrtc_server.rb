# frozen_string_literal: true

require "json"
require "utcp"
gem "webrtc-ruby", ">= 1.0.0"
require "webrtc"
require_relative "http_helpers"

WebRTC.init
port = Integer(ENV.fetch("PORT", "8084"))
peers = {}
peers_mutex = Mutex.new

def wait_for_ice(peer, timeout = 5)
  mutex = Mutex.new
  condition = ConditionVariable.new
  complete = peer.ice_gathering_state == :complete
  peer.on_ice_gathering_state_change do
    mutex.synchronize do
      complete = peer.ice_gathering_state == :complete
      condition.broadcast if complete
    end
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  mutex.synchronize do
    until complete
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break unless remaining.positive?
      condition.wait(mutex, remaining)
    end
  end
end

ExampleHTTP.server(port) do |server|
  server.mount_proc("/connect") do |request, response|
    payload = ExampleHTTP.request_json(request)
    candidates = []
    peer = WebRTC::RTCPeerConnection.new
    peer.on_ice_candidate { |candidate| candidates << candidate if candidate }
    peer.on_data_channel do |channel|
      channel.on_message do |event|
        envelope = JSON.parse(event.data)
        result = envelope.dig("args", "message") if envelope["tool"] == "echo"
        channel.send_text(JSON.generate(id: envelope["id"], result: result))
      rescue JSON::ParserError
        nil
      end
    end

    offer = WebRTC::RTCSessionDescription.new(type: :offer, sdp: payload.fetch("sdp"))
    peer.set_remote_description(offer).await
    answer = peer.create_answer.await
    peer.set_local_description(answer).await
    wait_for_ice(peer)
    peers_mutex.synchronize { peers[payload.fetch("peer_id")] = peer }
    ExampleHTTP.json(response, {
      sdp: peer.local_description.sdp,
      candidates: candidates.map(&:to_h),
      tools: [{ name: "echo", description: "Echo over a WebRTC DataChannel" }]
    })
  rescue StandardError => error
    ExampleHTTP.json(response, { error: error.message }, status: 500)
  end

  server.mount_proc("/candidate") do |request, response|
    payload = ExampleHTTP.request_json(request)
    peer = peers_mutex.synchronize { peers[payload["peer_id"]] }
    if peer
      candidate = WebRTC::RTCIceCandidate.new(UTCP::Utils.symbolize_keys(payload.fetch("candidate")))
      peer.add_ice_candidate(candidate).await
      ExampleHTTP.json(response, { ok: true })
    else
      ExampleHTTP.json(response, { error: "unknown peer" }, status: 404)
    end
  rescue StandardError => error
    ExampleHTTP.json(response, { error: error.message }, status: 400)
  end
end
