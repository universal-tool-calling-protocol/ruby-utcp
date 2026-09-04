# frozen_string_literal: true

module UTCP
  class CodeModeUtcpClient < Client
    AGENT_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Use `codemode.search_tools` before writing a Code Mode program when tool names are unknown.
      Call tools as `codemode.call_tool("manual.tool", key: value)`. Use the exact qualified name.
      Code Mode accepts a constrained Ruby subset: local variables, JSON-like literals, arithmetic,
      conditionals, bounded loops, and common Array/Hash/String transforms. The final expression or an
      explicit `return` is the result. Use `puts`, `print`, `p`, or `warn` for captured logs. The values
      `codemode.interfaces` and `codemode.get_tool_interface("manual.tool")` describe registered tools. Filesystem,
      process, constants, imports, reflection, eval, and direct network access are unavailable.
    PROMPT

    def call_tool_chain(code, timeout_value = nil, timeout: nil, max_steps: CodeMode::DEFAULT_MAX_STEPS)
      selected_timeout = timeout || timeout_value || CodeMode::DEFAULT_TIMEOUT
      CodeMode.new(self).execute(code, timeout: selected_timeout, max_steps: max_steps)
    end

    def get_all_tools_ruby_interfaces
      CodeMode.new(self).interfaces
    end

    def get_tool_interface(name)
      CodeMode.new(self).tool_interface(name)
    end
  end

  CodeModeClient = CodeModeUtcpClient
end
