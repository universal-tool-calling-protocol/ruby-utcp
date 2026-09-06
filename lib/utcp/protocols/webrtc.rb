# frozen_string_literal: true

module UTCP
  class WebRTCPeer
    def initialize(template, connection: nil)
      @template = template
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @pending = {}
      @io_mutex = Mutex.new
      @closed = false
      @candidates = []
      configuration = { disable_auto_negotiation: true, max_message_size: template.max_response_bytes }
      configuration[:ice_servers] = template.ice_servers unless template.ice_servers.empty?
      unless connection
        gem "webrtc-ruby", ">= 1.0.0"
        require "webrtc"
        require_relative "webrtc_native_cleanup"
        WebRTC.init
        @native_cleanup = WebRTCNativeCleanup.new
        connection = WebRTC::RTCPeerConnection.new(configuration)
      end
      @connection = connection
      install_candidate_handler
      @channel = @connection.create_data_channel(template.data_channel_name)
      install_channel_handlers
    rescue LoadError => error
      close
      raise MissingDependencyError,
            "WebRTC requires the optional 'webrtc-ruby' gem and libdatachannel: #{error.message}"
    rescue StandardError
      close
      raise
    end

    def connect
      @io_mutex.synchronize do
        @mutex.synchronize { assert_open! }
        connect_peer
      end
    end

    def connect_peer
      offer = @connection.create_offer.await
      # webrtc-ruby creates and installs the local offer in one native operation.
      wait_for_ice_gathering
      response = post_json("connect", "peer_id" => @template.peer_id, "sdp" => offer.sdp)
      answer = WebRTC::RTCSessionDescription.new(type: :answer, sdp: response.fetch("sdp"))
      @connection.set_remote_description(answer).await
      Array(response["candidates"]).each do |candidate|
        @connection.add_ice_candidate(WebRTC::RTCIceCandidate.new(Utils.symbolize_keys(candidate))).await
      rescue StandardError
        nil
      end
      @mutex.synchronize { @candidates.dup }.each { |candidate| post_candidate(candidate) }
      wait_for_channel
      response
    end

    def request(payload, timeout: @template.timeout)
      identifier = payload.fetch("id")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      state = { deadline: deadline }
      @mutex.synchronize do
        assert_open!
        raise ValidationError, "Duplicate WebRTC request id" if @pending.key?(identifier)
        if @pending.length >= @template.max_pending_requests
          raise ToolCallError, "WebRTC exceeds max_pending_requests"
        end
        @pending[identifier] = state
      end
      @io_mutex.synchronize do
        @mutex.synchronize { assert_open! }
        @channel.send_text(JSON.generate(payload))
      end
      @mutex.synchronize do
        loop do
          assert_open!
          return state[:response] if state.key?(:response)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise TimeoutError, "WebRTC response timed out" unless remaining.positive?
          @condition.wait(@mutex, remaining)
        end
      end
    ensure
      @mutex.synchronize { @pending.delete(identifier) if @pending[identifier].equal?(state) }
    end

    def close
      @mutex.synchronize do
        return nil if @closed
        @closed = true
        @pending.clear
        @candidates.clear
        @condition.broadcast
      end
      @io_mutex.synchronize do
        if @native_cleanup
          @native_cleanup.close(@channel, @connection)
        else
          begin
            @channel.close if @channel
            @channel.destroy if @channel&.respond_to?(:destroy)
          ensure
            @connection.close if @connection
          end
        end
      end
      nil
    end

    private

    private :connect_peer

    def assert_open!
      raise ToolCallError, "WebRTC peer closed" if @closed
      raise ToolCallError, @failure if @failure
    end

    def fail_peer(message)
      @mutex.synchronize do
        @failure ||= message unless @closed
        @condition.broadcast
      end
    end

    def install_candidate_handler
      @connection.on_ice_candidate do |candidate|
        @mutex.synchronize { @candidates << candidate unless @closed } if candidate
      end
    end

    def install_channel_handlers
      @channel_open = false
      @channel.on_open do
        @mutex.synchronize do
          @channel_open = true unless @closed
          @condition.broadcast
        end
      end
      @channel.on_close { fail_peer("WebRTC channel closed") } if @channel.respond_to?(:on_close)
      @channel.on_message do |message|
        if message.data.bytesize > @template.max_response_bytes
          fail_peer("WebRTC response exceeds max_response_bytes")
          next
        end
        envelope = JSON.parse(message.data)
        next unless envelope.is_a?(Hash)
        identifier = envelope["id"]
        @mutex.synchronize do
          state = @pending[identifier]
          next unless state && !@closed && !state.key?(:response)
          next if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= state[:deadline]
          state[:response] = envelope.key?("result") ? envelope["result"] : envelope
          @condition.broadcast
        end
      rescue JSON::ParserError
        nil
      end
    end

    def wait_for_ice_gathering
      return unless @connection.respond_to?(:on_ice_gathering_state_change)

      complete = @connection.ice_gathering_state == :complete
      @connection.on_ice_gathering_state_change do |state|
        @mutex.synchronize do
          complete = state == :complete
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
        loop do
          assert_open!
          return if yield
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
      http.write_timeout = @template.timeout if http.respond_to?(:write_timeout=)
      response = Timeout.timeout(@template.timeout, TimeoutError, "WebRTC signaling timed out") do
        http.start do |connection|
          connection.request(request) do |incoming|
            incoming.body = LimitedHTTPResponse.new(incoming, @template.max_response_bytes).body
          end
        end
      end
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
      response = peer_for(client, template).connect
      ResponseByteBudget.new(template.max_response_bytes, "WebRTC discovery").consume_value(response)
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
      deregister_manual(client, template)
      client.logger.warn("Unable to register WebRTC manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def deregister_manual(client, template)
      peers = @mutex.synchronize do
        keys = @peers.keys.select { |owner, name, *_rest| owner.equal?(client) && name == template.name }
        keys.map { |key| @peers.delete(key) }
      end
      peers.each(&:close)
      nil
    end

    def call_tool(client, tool_name, tool_args, template)
      assert_webrtc_template!(template)
      identifier = SecureRandom.uuid
      response = peer_for(client, template).request(
        {
          "id" => identifier,
          "tool" => tool_name.to_s.split(".").last,
          "args" => Utils.stringify_keys(tool_args || {})
        },
        timeout: template.timeout
      )
      ResponseByteBudget.new(template.max_response_bytes, "WebRTC").consume_value(response)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("WebRTC tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_webrtc_template!(template)
      raise ValidationError, "WebRTC protocol requires a WebRtcCallTemplate" unless template.is_a?(WebRtcCallTemplate)

      assert_no_auth!(template)
    end

    def peer_for(client, template)
      @mutex.synchronize { @peers[peer_key(client, template)] ||= @peer_factory.call(template) }
    end

    def peer_key(client, template)
      [client, template.name, template.signaling_server, template.peer_id, template.data_channel_name,
       template.max_response_bytes, template.max_pending_requests]
    end
  end
  WebrtcCommunicationProtocol = WebRTCProtocol
  WebRTCCommunicationProtocol = WebRTCProtocol
end
