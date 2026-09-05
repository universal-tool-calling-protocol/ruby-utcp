# frozen_string_literal: true

module UTCP
  class TextProtocol < CommunicationProtocol
    def register_manual(client, template)
      assert_template!(template)
      data = Utils.parse_document(template.content, source: "text manual")
      manual = if openapi?(data)
                 OpenAPIConverter.new(
                   data,
                   spec_url: "text://content",
                   call_template_name: template.name,
                   auth_tools: template.auth_tools,
                   base_url: template.base_url
                 ).convert
               else
                 Manual.from_h(data)
               end
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register text manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, _tool_name, _tool_args, template)
      assert_template!(template)
      template.content
    end

    private

    def assert_template!(template)
      raise ValidationError, "text protocol requires a TextCallTemplate" unless template.is_a?(TextCallTemplate)

      assert_no_auth!(template)
    end

    def openapi?(data)
      data.is_a?(Hash) && (data.key?("openapi") || data.key?("swagger") || data.key?("paths"))
    end
  end
  TextCommunicationProtocol = TextProtocol
end
