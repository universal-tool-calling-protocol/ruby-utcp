# frozen_string_literal: true

module UTCP
  class Error < StandardError; end
  UtcpError = Error
  UTCPError = Error

  class ValidationError < Error
    attr_reader :path

    def initialize(message, path: nil)
      @path = path
      super(path ? "#{path}: #{message}" : message)
    end
  end

  class SerializerValidationError < ValidationError; end
  UtcpSerializerValidationError = SerializerValidationError
  class VariableNotFoundError < Error
    attr_reader :variable_name

    def initialize(variable_name)
      @variable_name = variable_name
      super("Required variable not found: #{variable_name}")
    end
  end
  UtcpVariableNotFound = VariableNotFoundError
  UtcpVariableNotFoundException = VariableNotFoundError

  class ToolNotFoundError < Error; end
  class ManualAlreadyRegisteredError < Error; end
  class ProtocolNotFoundError < Error; end
  class ProtocolNotAllowedError < Error; end
  class MissingDependencyError < Error; end
  class AuthenticationError < Error; end
  class ToolCallError < Error
    attr_reader :tool_name, :status, :response_body

    def initialize(message, tool_name: nil, status: nil, response_body: nil)
      @tool_name = tool_name
      @status = status
      @response_body = response_body
      super(message)
    end
  end
  class SecurityError < Error; end
  class TimeoutError < ToolCallError; end
end
