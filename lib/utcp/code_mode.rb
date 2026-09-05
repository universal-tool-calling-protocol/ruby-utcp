# frozen_string_literal: true

require "json"
require "ripper"
require "timeout"

module UTCP
  # Executes a deliberately small, non-eval Ruby subset for composing UTCP tools.
  # The interpreter only exposes JSON-like values and explicit tool helpers.
  class CodeMode
    DEFAULT_TIMEOUT = 30
    DEFAULT_MAX_STEPS = 100_000
    MAX_CODE_BYTES = 64 * 1024
    MAX_LOG_BYTES = 1024 * 1024
    MAX_VALUE_BYTES = 30 * 1024 * 1024
    MAX_VALUE_ITEMS = 10_000
    MAX_INTEGER_BITS = MAX_VALUE_BYTES * 8

    attr_reader :client

    def initialize(client)
      @client = client
    end

    def execute(code, timeout: DEFAULT_TIMEOUT, max_steps: DEFAULT_MAX_STEPS)
      source = String(code)
      raise CodeModeLimitError, "Code exceeds #{MAX_CODE_BYTES} bytes" if source.bytesize > MAX_CODE_BYTES

      seconds = Float(timeout)
      raise CodeModeLimitError, "timeout must be greater than zero" unless seconds.positive?

      evaluator = Evaluator.new(
        client,
        interfaces: interfaces,
        timeout: seconds,
        max_steps: Integer(max_steps)
      )
      result = Timeout.timeout(seconds, CodeModeTimeoutError) { evaluator.execute(source) }
      { "result" => result, "logs" => evaluator.logs.dup }
    rescue CodeModeTimeoutError
      raise CodeModeTimeoutError, "Code Mode execution exceeded #{timeout} seconds"
    rescue CodeModeExecutionError => error
      logs = defined?(evaluator) && evaluator ? evaluator.logs : error.logs
      raise CodeModeExecutionError.new(error.message, logs: logs)
    rescue CodeModeError
      raise
    rescue StandardError => error
      logs = defined?(evaluator) && evaluator ? evaluator.logs : []
      raise CodeModeExecutionError.new("Code Mode execution failed: #{error.message}", logs: logs)
    end

    def interfaces
      InterfaceGenerator.new(client.list_tools).render
    end

    def tool_interface(name)
      tool = client.list_tools.find { |candidate| candidate.name == name.to_s }
      raise ToolNotFoundError, "Tool not found: #{name}" unless tool

      InterfaceGenerator.tool_descriptor(tool)
    end
  end
end

require_relative "code_mode/interface_generator"
require_relative "code_mode/evaluator"
require_relative "code_mode/expressions"
require_relative "code_mode/control_flow"
require_relative "code_mode/runtime"
require_relative "code_mode/value_methods"
require_relative "code_mode/value_limits"
require_relative "code_mode/client"
