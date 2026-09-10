# frozen_string_literal: true

require "json"

module CodingAgent
  class ExecutionTrace
    def initialize(output)
      @output = output
      @program = 0
      @step = 0
    end

    def program(code)
      @program += 1
      @step = 0
      write("Code Mode #{@program}: program", code)
    end

    def step(name, arguments, render: nil)
      @step += 1
      label = "Tool #{@program}.#{@step}: #{name}"
      write("#{label} arguments", arguments)
      result = yield(label)
      write("#{label} output", render ? render.call(result) : result)
      result
    rescue StandardError => error
      write("#{label} error", error.message)
      raise
    end

    def completed(execution)
      write("Code Mode #{@program}: captured logs", execution.fetch("logs"))
      write("Code Mode #{@program}: result", execution.fetch("result"))
    end

    def failed(error)
      write("Code Mode request error", error.message)
      write("Code Mode #{@program}: captured logs", error.logs) if error.respond_to?(:logs)
    end

    def write(label, value)
      @output.puts("\n[#{label}]")
      @output.puts(value.is_a?(String) ? value : JSON.pretty_generate(value))
      @output.flush
    end
  end

  # Extend only this example's client, so every real tool call within a program
  # is visible even when the program discards or summarizes that tool's result.
  module ToolTracing
    attr_accessor :execution_trace

    def call_tool(name, arguments = {})
      return super unless execution_trace

      execution_trace.step(name, arguments) { super }
    end

    def call_tool_streaming(name, arguments = {})
      return enum_for(__method__, name, arguments) unless block_given?
      return super { |chunk| yield chunk } unless execution_trace

      execution_trace.step(name, arguments) do |label|
        super do |chunk|
          execution_trace.write("#{label} chunk", chunk)
          yield chunk
        end
      end
    end

    def search_tools(query, **options)
      return super unless execution_trace

      execution_trace.step("codemode.search_tools", { "query" => query }.merge(options),
                           render: ->(tools) { tools.map(&:to_h) }) { super }
    end
  end
end
