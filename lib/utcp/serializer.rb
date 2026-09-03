# frozen_string_literal: true

module UTCP
  class Serializer
    def initialize(model_class)
      @model_class = model_class
    end

    def to_dict(object)
      unless object.respond_to?(:to_h)
        raise SerializerValidationError, "#{object.class} cannot be serialized"
      end

      object.to_h
    end
    alias to_h to_dict

    def validate_dict(value)
      @model_class.from_h(value)
    rescue Error
      raise
    rescue StandardError => error
      raise SerializerValidationError, error.message
    end
    alias from_h validate_dict

    def copy(object)
      validate_dict(to_dict(object))
    end
  end

  class AuthSerializer < Serializer
    def initialize
      super(Auth)
    end
  end

  class CallTemplateSerializer < Serializer
    def initialize
      super(CallTemplate)
    end
  end

  class JsonSchemaSerializer < Serializer
    def initialize
      super(JsonSchema)
    end
  end
  JSONSchemaSerializer = JsonSchemaSerializer

  class ToolSerializer < Serializer
    def initialize
      super(Tool)
    end
  end

  class ManualSerializer < Serializer
    def initialize
      super(Manual)
    end
  end
  UtcpManualSerializer = ManualSerializer

  class ClientConfigSerializer < Serializer
    def initialize
      super(ClientConfig)
    end
  end
  UtcpClientConfigSerializer = ClientConfigSerializer
end

