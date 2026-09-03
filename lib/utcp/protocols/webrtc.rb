# frozen_string_literal: true

module UTCP
  class WebRTCPeer
    def initialize(template)
      gem "webrtc-ruby", ">= 1.0.0"
      require "webrtc"
      WebRTC.init
      @template = template
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @responses = {}
      @candidates = []
      configuration = template.ice_servers.empty? ? nil : { ice_servers: template.ice_servers }
      @connection = WebRTC::RTCPeerConnection.new(configuration)
      install_candidate_handler
      @channel = @connection.create_data_channel(template.data_channel_name)
      install_channel_handlers
    rescue LoadError => error
      raise MissingDependencyError,
            "WebRTC requires the optional 'webrtc-ruby' gem and libdatachannel: #{error.message}"
    end

    def connect
      offer = @connection.create_offer.await
      @connection.set_local_description(offer).await
      wait_for_ice_gathering
      response = post_json("connect", "peer_id" => @template.peer_id, "sdp" => @connection.local_description.sdp)
      answer = WebRTC::RTCSessionDescription.new(type: :answer, sdp: response.fetch("sdp"))
      @connection.set_remote_description(answer).await
      Array(response["candidates"]).each do |candidate|
        @connection.add_ice_candidate(WebRTC::RTCIceCandidate.new(Utils.symbolize_keys(candidate))).await
      rescue StandardError
        nil
      end
      @candidates.each { |candidate| post_candidate(candidate) }
      wait_for_channel
      response
    end

    def request(payload, timeout: @template.timeout)
      identifier = payload.fetch("id")
      @channel.send_text(JSON.generate(payload))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        until @responses.key?(identifier)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise TimeoutError, "WebRTC response timed out" unless remaining.positive?
          @condition.wait(@mutex, remaining)
        end
        @responses.delete(identifier)
      end
    end

    def close
      @channel.close if @channel
      @channel.destroy if @channel&.respond_to?(:destroy)
      @connection.close if @connection
    rescue StandardError
      nil
    end

    private

    def install_candidate_handler
      @connection.on_ice_candidate do |candidate|
        @mutex.synchronize { @candidates << candidate } if candidate
      end
    end

    def install_channel_handlers
      @channel_open = false
      @channel.on_open do
        @mutex.synchronize do
          @channel_open = true
          @condition.broadcast
        end
      end
      @channel.on_message do |message|
        envelope = JSON.parse(message.data)
        identifier = envelope["id"]
        @mutex.synchronize do
          @responses[identifier] = envelope.key?("result") ? envelope["result"] : envelope
          @condition.broadcast
        end
      rescue JSON::ParserError
        nil
      end
    end

    def wait_for_ice_gathering
      return unless @connection.respond_to?(:on_ice_gathering_state_change)

      complete = @connection.ice_gathering_state == :complete
      @connection.on_ice_gathering_state_change do
        @mutex.synchronize do
          complete = @connection.ice_gathering_state == :complete
          @condition.broadcast if complete
        end
      end
      wait_for_flag(@template.timeout) { complete }
    rescue TimeoutError
      # Trickle ICE remains valid when a backend does not expose a reliable gathering event.
      nil
    end

    def wait_for_channel
      wait_for_flag(@template.timeout) { @channel_open || @channel.ready_state == :open }
    end

    def wait_for_flag(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        until yield
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise TimeoutError, "WebRTC connection timed out" unless remaining.positive?
          @condition.wait(@mutex, remaining)
        end
      end
    end

    def post_candidate(candidate)
      value = candidate.respond_to?(:to_h) ? candidate.to_h : candidate
      post_json("candidate", "peer_id" => @template.peer_id, "candidate" => value)
    rescue StandardError
      nil
    end

    def post_json(path, payload)
      url = "#{@template.signaling_server.sub(%r{/+\z}, "")}/#{path}"
      uri = URLSecurity.validate!(url, context: "WebRTC signaling")
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [@template.timeout, 10].min
      http.read_timeout = @template.timeout
      response = http.start { |connection| connection.request(request) }
      unless response.code.to_i.between?(200, 299)
        raise ToolCallError.new("WebRTC signaling failed with status #{response.code}",
                                status: response.code.to_i, response_body: response.body)
      end
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError => error
      raise SerializerValidationError, "Invalid WebRTC signaling response: #{error.message}"
    end
  end

  class WebRTCProtocol < CommunicationProtocol
    def initialize(peer_factory: nil)
      @peer_factory = peer_factory || ->(template) { WebRTCPeer.new(template) }
      @peers = {}
      @mutex = Mutex.new
    end

    def register_manual(client, template)
      assert_webrtc_template!(template)
      response = peer_for(template).connect
      payload = if response.is_a?(Hash) && response.key?("tools") && !response.key?("utcp_version")
                  {
                    "utcp_version" => VERSION,
                    "manual_version" => "1.0.0",
                    "tools" => response["tools"]
                  }
                else
                  response
                end
      success(template, manual_from_payload(template, payload, source: "WebRTC signaling response"))
    rescue StandardError => error
      client.logger.warn("Unable to register WebRTC manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def deregister_manual(_client, template)
      peer = @mutex.synchronize { @peers.delete(peer_key(template)) }
      peer&.close
      nil
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_webrtc_template!(template)
      identifier = SecureRandom.uuid
      peer_for(template).request(
        {
          "id" => identifier,
          "tool" => tool_name.to_s.split(".").last,
          "args" => Utils.stringify_keys(tool_args || {})
        },
        timeout: template.timeout
      )
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("WebRTC tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_webrtc_template!(template)
      return if template.is_a?(WebRtcCallTemplate)

      raise ValidationError, "WebRTC protocol requires a WebRtcCallTemplate"
    end

    def peer_for(template)
      @mutex.synchronize { @peers[peer_key(template)] ||= @peer_factory.call(template) }
    end

    def peer_key(template)
      [template.name, template.signaling_server, template.peer_id, template.data_channel_name].join("\0")
    end
  end
  WebrtcCommunicationProtocol = WebRTCProtocol
  WebRTCCommunicationProtocol = WebRTCProtocol
end
