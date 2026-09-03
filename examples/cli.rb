# frozen_string_literal: true

require "base64"
require "json"
require "rbconfig"
require "utcp"

# A CLI manual is itself discovered by executing a command. The discovered tool also uses CLI.
manual = {
  utcp_version: "1.1.0",
  manual_version: "1.0.0",
  tools: [{
    name: "greet",
    inputs: { type: "object", properties: { name: { type: "string" } }, required: ["name"] },
    tool_call_template: {
      call_template_type: "cli",
      commands: [{ command: "printf 'Hello, %s!' UTCP_ARG_name_UTCP_END" }]
    }
  }]
}
encoded = Base64.strict_encode64(JSON.generate(manual))
discovery = "#{RbConfig.ruby} -rbase64 -e 'print Base64.decode64(ARGV.fetch(0))' #{encoded}"

client = UTCP::Client.create(config: {
  manual_call_templates: [{
    name: "shell",
    call_template_type: "cli",
    commands: [{ command: discovery }]
  }]
})

puts client.call_tool("shell.greet", name: "Ruby")
