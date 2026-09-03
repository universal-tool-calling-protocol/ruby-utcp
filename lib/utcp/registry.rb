# frozen_string_literal: true

require "thread"

module UTCP
  @registry_mutex = Mutex.new
  @call_template_classes = {}
  @auth_classes = {}
  @protocols = {}

  class << self
    def register_call_template(type, klass)
      validate_plugin_type!(type)
      unless klass.respond_to?(:new)
        raise ArgumentError, "call template implementation must be a class-like object"
      end
      @registry_mutex.synchronize { @call_template_classes[type.to_s] = klass }
      klass
    end

    def call_template_class(type)
      @registry_mutex.synchronize { @call_template_classes[type.to_s] }
    end

    def call_template_types
      @registry_mutex.synchronize { @call_template_classes.keys.sort }
    end

    def register_auth(type, klass)
      validate_plugin_type!(type)
      @registry_mutex.synchronize { @auth_classes[type.to_s] = klass }
      klass
    end

    def auth_class(type)
      @registry_mutex.synchronize { @auth_classes[type.to_s] }
    end

    def register_protocol(type, implementation)
      validate_plugin_type!(type)
      protocol = implementation.is_a?(Class) ? implementation.new : implementation
      required = %i[register_manual deregister_manual call_tool]
      missing = required.reject { |method_name| protocol.respond_to?(method_name) }
      raise ArgumentError, "protocol is missing: #{missing.join(', ')}" unless missing.empty?

      @registry_mutex.synchronize { @protocols[type.to_s] = protocol }
      protocol
    end

    def protocol(type)
      @registry_mutex.synchronize { @protocols[type.to_s] }
    end

    def protocol_types
      @registry_mutex.synchronize { @protocols.keys.sort }
    end

    private

    def validate_plugin_type!(type)
      unless type.to_s.match?(/\A[a-zA-Z0-9_]+\z/)
        raise ArgumentError, "plugin type must contain only letters, numbers, and underscores"
      end
    end
  end
end

