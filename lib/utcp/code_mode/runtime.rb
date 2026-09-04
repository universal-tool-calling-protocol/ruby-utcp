# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      private

      def invoke_runtime_api(method_name, arguments, block)
        raise CodeModeSyntaxError, "codemode.#{method_name} does not accept a block" if block

        case method_name
        when "call_tool"
          require_arity!("codemode.call_tool", arguments, 1..2)
          safe_tool_value(@client.call_tool(arguments[0], tool_arguments(arguments[1])))
        when "call_tool_stream", "call_tool_streaming"
          require_arity!("codemode.#{method_name}", arguments, 1..2)
          safe_tool_value(@client.call_tool_streaming(arguments[0], tool_arguments(arguments[1])).to_a)
        when "search_tools"
          require_arity!("codemode.search_tools", arguments, 1..2)
          options = arguments[1].is_a?(Hash) ? arguments[1] : {}
          limit = arguments[1].is_a?(Numeric) ? arguments[1] : options.fetch("limit", 10)
          safe_tool_value(@client.search_tools(arguments[0].to_s, limit: Integer(limit)).map do |tool|
            InterfaceGenerator.tool_descriptor(tool)
          end)
        when "get_tool_interface"
          require_arity!("codemode.get_tool_interface", arguments, 1)
          tool = @client.list_tools.find { |candidate| candidate.name == arguments.first.to_s }
          raise ToolNotFoundError, "Tool not found: #{arguments.first}" unless tool
          safe_tool_value(InterfaceGenerator.tool_descriptor(tool))
        when "interfaces"
          require_arity!("codemode.interfaces", arguments, 0)
          @interfaces.dup
        when "get"
          runtime_get(arguments)
        else
          raise CodeModeSyntaxError, "Method #{method_name.inspect} is not available on codemode"
        end
      end

      def runtime_get(arguments)
        require_arity!("codemode.get", arguments, 2..3)
        receiver, key, default = arguments
        return receiver.fetch(key, default) if receiver.is_a?(Hash)
        return receiver.fetch(Integer(key), default) if receiver.is_a?(Array)
        return receiver[key] || default if receiver.is_a?(String)

        raise CodeModeExecutionError, "codemode.get requires a hash, array, or string"
      rescue IndexError, TypeError
        default
      end

      def tool_arguments(value)
        return {} if value.nil?
        raise CodeModeSyntaxError, "Tool arguments must be a hash" unless value.is_a?(Hash)

        safe_tool_value(value)
      end

      def log(kind, values)
        rendered = values.map { |value| kind == "p" ? value.inspect : value.to_s }.join(kind == "print" ? "" : " ")
        rendered = "[WARN] #{rendered}" if kind == "warn"
        bytes = rendered.bytesize
        raise CodeModeLimitError, "Code Mode log limit exceeded" if @log_bytes + bytes > MAX_LOG_BYTES

        @logs << rendered
        @log_bytes += bytes
      end
    end
  end
end
