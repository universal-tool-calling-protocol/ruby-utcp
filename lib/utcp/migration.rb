# frozen_string_literal: true

require "shellwords"

module UTCP
  module Migration
    module_function

    def config_v0_1_to_v1_1(config)
      data = Utils.stringify_keys(Utils.deep_copy(Utils.hash!(config, "v0.1 config")))
      providers = Array(data.delete("providers"))
      existing = Array(data["manual_call_templates"])
      data["manual_call_templates"] = existing + providers.map { |provider| migrate_provider(provider) }
      data["variables"] ||= {}
      data
    end

    def manual_v0_1_to_v1_1(manual)
      data = Utils.stringify_keys(Utils.deep_copy(Utils.hash!(manual, "v0.1 manual")))
      provider_info = Utils.stringify_keys(data.delete("provider_info") || {})
      info = Utils.stringify_keys(data["info"] || {})
      info["title"] ||= provider_info["name"] || "UTCP Manual"
      info["version"] ||= provider_info["version"] || "1.0.0"
      info["description"] ||= provider_info["description"] if provider_info["description"]

      {
        "manual_version" => "1.0.0",
        "utcp_version" => VERSION,
        "info" => info,
        "tools" => Array(data["tools"]).map { |tool| migrate_tool(tool) }
      }
    end

    def v0_1_manual?(value)
      return false unless value.is_a?(Hash)

      data = Utils.stringify_keys(value)
      data.key?("provider_info") || Array(data["tools"]).any? do |tool|
        tool.is_a?(Hash) && (tool.key?("provider") || tool.key?("parameters") || tool.key?(:provider))
      end
    end

    def migrate_provider(provider)
      source = Utils.stringify_keys(Utils.deep_copy(Utils.hash!(provider, "provider")))
      type = source.delete("provider_type") || source.delete("type") || source["call_template_type"]
      raise ValidationError, "v0.1 provider is missing provider_type" if type.nil? || type.to_s.empty?

      source["call_template_type"] = type.to_s
      source["http_method"] = source.delete("method") if source["method"] && !source["http_method"]
      source["working_dir"] = source.delete("cwd") if source["cwd"] && !source["working_dir"]
      source["working_dir"] = source.delete("working_directory") if source["working_directory"] && !source["working_dir"]

      if type.to_s == "cli" && source["command"]
        command = source.delete("command").to_s
        arguments = Array(source.delete("args")).map { |argument| migrate_cli_argument(argument) }
        source["commands"] ||= [{ "command" => ([command] + arguments).join(" "), "append_to_final_output" => true }]
      end
      if type.to_s == "http" && source.key?("body") && !source.key?("body_field")
        source.delete("body")
        source["body_field"] = "body"
      end
      source
    end

    def migrate_tool(tool)
      source = Utils.stringify_keys(Utils.deep_copy(Utils.hash!(tool, "tool")))
      source["inputs"] ||= source.delete("parameters") || {}
      source["outputs"] ||= {}
      source["tags"] ||= []
      provider = source.delete("provider") || source.delete("tool_provider")
      source["tool_call_template"] ||= migrate_provider(provider) if provider
      source
    end

    def migrate_cli_argument(argument)
      converted = argument.to_s.gsub(/\$\{([A-Za-z0-9_]+)\}|\$([A-Za-z0-9_]+)/) do
        "UTCP_ARG_#{Regexp.last_match(1) || Regexp.last_match(2)}_UTCP_END"
      end
      converted.include?("UTCP_ARG_") ? converted : Shellwords.escape(converted)
    end

    class << self
      alias migrate_config config_v0_1_to_v1_1
      alias migrate_manual manual_v0_1_to_v1_1
    end
  end
end

