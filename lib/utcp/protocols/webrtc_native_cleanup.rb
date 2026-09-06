# frozen_string_literal: true

module UTCP
  # Stock webrtc-ruby 1.0 binds these waiting destructors without releasing the
  # GVL. Keep the compatibility binding local to UTCP-owned objects: callbacks
  # must be able to finish while native destruction waits for them.
  class WebRTCNativeCleanup
    MUTEX = Mutex.new

    def self.bindings
      MUTEX.synchronize do
        @bindings ||= Module.new do
          extend ::FFI::Library
          ffi_lib WebRTC::FFI::LIB_PATH
          attach_function :destroy_channel, :webrtc_data_channel_destroy, [:pointer], :void, blocking: true
          attach_function :destroy_peer, :webrtc_peer_connection_destroy, [:pointer], :void, blocking: true
        end
      end
    end

    def initialize
      @bindings = self.class.bindings
    end

    def close(channel, connection)
      # WebRTCPeer serializes this transfer with all native I/O and elects one
      # closer. Detach handles before callbacks can observe or reuse them.
      channel_pointer = channel.instance_variable_get(:@ptr) if channel
      peer_pointer = connection.ptr if connection
      channel.instance_variable_set(:@ptr, nil) if channel
      connection.instance_variable_set(:@ptr, nil) if connection
      begin
        @bindings.destroy_channel(channel_pointer) if channel_pointer && !channel_pointer.null?
      ensure
        @bindings.destroy_peer(peer_pointer) if peer_pointer && !peer_pointer.null?
      end
    end
  end
end
