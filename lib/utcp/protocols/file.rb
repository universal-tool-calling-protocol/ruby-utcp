# frozen_string_literal: true

require "pathname"

module UTCP
  class FileProtocol < CommunicationProtocol
    def register_manual(client, template)
      assert_template!(template)
      path = resolve_path(client, template.file_path)
      data = Utils.load_document(path)
      manual = if openapi?(data)
                 OpenAPIConverter.new(
                   data,
                   spec_url: Pathname.new(path).expand_path.to_s,
                   call_template_name: template.name,
                   auth_tools: template.auth_tools
                 ).convert
               else
                 Manual.from_h(data)
               end
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register file manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(client, _tool_name, _tool_args, template)
      assert_template!(template)
      File.read(resolve_path(client, template.file_path), mode: "r:bom|utf-8")
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ToolCallError, "Unable to read tool file: #{error.message}"
    end

    private

    def assert_template!(template)
      raise ValidationError, "file protocol requires a FileCallTemplate" unless template.is_a?(FileCallTemplate)

      assert_no_auth!(template)
    end

    def resolve_path(client, path)
      File.expand_path(path, client.root_dir)
    end

    def openapi?(data)
      data.is_a?(Hash) && (data.key?("openapi") || data.key?("swagger") || data.key?("paths"))
    end
  end
  FileCommunicationProtocol = FileProtocol
end
