# frozen_string_literal: true

require "json"

module UTCP
  class CommunicationProtocol
    def register_manual(_client, _manual_call_template)
      raise NotImplementedError
    end

    def deregister_manual(_client, _manual_call_template)
      nil
    end

    def call_tool(_client, _tool_name, _tool_args, _tool_call_template)
      raise NotImplementedError
    end

    def call_tool_streaming(client, tool_name, tool_args, tool_call_template)
      return enum_for(__method__, client, tool_name, tool_args, tool_call_template) unless block_given?

      yield call_tool(client, tool_name, tool_args, tool_call_template)
    end

    private

    def manual_from_payload(template, payload, source: "protocol response")
      data = if payload.is_a?(String)
               Utils.parse_document(payload, source: source)
             else
               Utils.stringify_keys(payload)
             end
      data = { "tools" => data } if data.is_a?(Array)
      data = Migration.manual_v0_1_to_v1_1(data) if Migration.v0_1_manual?(data)
      data = Utils.hash!(data, source)
      data["utcp_version"] ||= VERSION
      data["manual_version"] ||= "1.0.0"
      data["tools"] = Utils.array!(data.fetch("tools", []), "#{source}.tools").map do |raw_tool|
        tool = Utils.stringify_keys(Utils.hash!(raw_tool, "#{source}.tool"))
        tool["tool_call_template"] ||= tool.delete("tool_provider") || template.to_h
        tool
      end
      Manual.from_h(data)
    end

    def decode_json_or_text(value)
      return value unless value.is_a?(String)

      stripped = value.strip
      return value if stripped.empty? || !stripped.start_with?("{", "[", '"') && stripped !~ /\A(?:true|false|null|-?\d)/

      JSON.parse(stripped)
    rescue JSON::ParserError
      value
    end

    def substitute_message_template(value, arguments)
      args = Utils.stringify_keys(arguments || {})
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s] = substitute_message_template(item, args)
        end
      when Array
        value.map { |item| substitute_message_template(item, args) }
      when String
        value.gsub(/UTCP_ARG_([A-Za-z0-9_]+)_UTCP_ARG/) do
          name = Regexp.last_match(1)
          raise ToolCallError, "Missing required transport argument: #{name}" unless args.key?(name)

          replacement = args[name]
          replacement.is_a?(String) ? replacement : JSON.generate(replacement)
        end
      else
        value
      end
    end

    def success(template, manual)
      RegisterManualResult.new(
        manual_call_template: template,
        manual: manual,
        success: true,
        errors: []
      )
    end

    def failure(template, error)
      RegisterManualResult.new(
        manual_call_template: template,
        manual: Manual.new(tools: [], manual_version: "0.0.0"),
        success: false,
        errors: [error.is_a?(Exception) ? error.message : error.to_s]
      )
    end
  end
end
