# frozen_string_literal: true

require "utcp"

# Requires Ruby 3.1+, `gem "webrtc-ruby"`, and libdatachannel.
# POST /connect exchanges SDP and returns {sdp, candidates, tools}; /candidate accepts ICE.
client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "rtc",
    call_template_type: "webrtc",
    signaling_server: ENV.fetch("UTCP_WEBRTC_SIGNALING", "http://localhost:8084"),
    peer_id: ENV.fetch("UTCP_WEBRTC_PEER_ID", "ruby-client"),
    data_channel_name: "utcp",
    ice_servers: [{ urls: "stun:stun.l.google.com:19302" }]
  }]
})

puts client.call_tool("rtc.echo", message: "Hello over WebRTC").inspect
client.close
