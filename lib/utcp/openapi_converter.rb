# frozen_string_literal: true

require "uri"

module UTCP
  class OpenAPIConverter
    HTTP_METHODS = %w[get post put delete patch head options].freeze

    def initialize(spec, spec_url: nil, call_template_name: nil, auth_tools: nil, base_url: nil)
      @spec = Utils.stringify_keys(Utils.hash!(spec, "OpenAPI document"))
      @spec_url = spec_url
      @call_template_name = call_template_name
      @auth_tools = auth_tools
      @base_url = base_url
    end

    def convert
      paths = @spec["paths"]
      raise ValidationError, "OpenAPI document must contain a paths object" unless paths.is_a?(Hash)

      tools = []
      paths.each do |path, path_item|
        next unless path_item.is_a?(Hash)

        HTTP_METHODS.each do |method|
          operation = path_item[method]
          next unless operation.is_a?(Hash)

          tools << convert_operation(path, method, path_item, operation)
        end
      end

      Manual.new(
        utcp_version: VERSION,
        manual_version: "1.0.0",
        info: @spec["info"] || {},
        tools: tools
      )
    end

    private

    def convert_operation(path, method, path_item, operation)
      parameters = Array(path_item["parameters"]) + Array(operation["parameters"])
      properties = {}
      required = []
      header_fields = []
      body_field = "body"

      parameters.each do |parameter|
        next unless parameter.is_a?(Hash)

        parameter = Utils.stringify_keys(parameter)
        name = parameter["name"].to_s
        next if name.empty?

        if parameter["in"] == "body"
          properties[body_field] = resolve_schema(parameter["schema"] || {})
          required << body_field if parameter["required"]
        else
          properties[name] = resolve_schema(parameter["schema"] || parameter_schema(parameter))
          required << name if parameter["required"] || parameter["in"] == "path"
          header_fields << name if parameter["in"] == "header"
        end
      end

      request_body = operation["requestBody"]
      if request_body.is_a?(Hash)
        content_type, media = Array(request_body["content"]).first
        if media.is_a?(Hash)
          properties[body_field] = resolve_schema(media["schema"] || {})
          required << body_field if request_body["required"]
        end
      else
        content_type = nil
      end

      tool_name = operation["operationId"].to_s
      tool_name = generated_name(method, path) if tool_name.empty?
      description = operation["description"] || operation["summary"] || "#{method.upcase} #{path}"
      input_schema = { "type" => "object", "properties" => properties }
      input_schema["required"] = required.uniq unless required.empty?

      Tool.new(
        name: tool_name,
        description: description.to_s,
        inputs: input_schema,
        outputs: response_schema(operation),
        tags: Array(operation["tags"]),
        tool_call_template: HttpCallTemplate.new(
          name: tool_name,
          url: join_url(resolve_base_url, path),
          http_method: method.upcase,
          content_type: content_type || Array(operation["consumes"]).first || "application/json",
          body_field: body_field,
          header_fields: header_fields,
          auth: operation_requires_auth?(operation) ? @auth_tools : nil
        )
      )
    end

    def parameter_schema(parameter)
      parameter.each_with_object({}) do |(key, value), schema|
        schema[key] = value if %w[type format enum default items minimum maximum pattern minLength maxLength].include?(key)
      end
    end

    def resolve_schema(schema, seen = [])
      data = Utils.stringify_keys(schema || {})
      reference = data["$ref"]
      return data unless reference&.start_with?("#/")
      return {} if seen.include?(reference)

      resolved = reference.sub(%r{\A#/}, "").split("/").reduce(@spec) do |node, component|
        break nil unless node.is_a?(Hash)

        node[component.gsub("~1", "/").gsub("~0", "~")]
      end
      resolved ? resolve_schema(resolved, seen + [reference]) : data
    end

    def response_schema(operation)
      responses = operation["responses"]
      return {} unless responses.is_a?(Hash)

      _status, response = responses.find { |status, _value| status.to_s.match?(/\A2\d\d\z/) } || responses.first
      return {} unless response.is_a?(Hash)

      if response["content"].is_a?(Hash)
        media = response["content"].values.first
        resolve_schema(media.is_a?(Hash) ? media["schema"] : {})
      else
        resolve_schema(response["schema"] || {})
      end
    end

    def operation_requires_auth?(operation)
      security = operation.key?("security") ? operation["security"] : @spec["security"]
      security.is_a?(Array) && !security.empty?
    end

    def resolve_base_url
      return @base_url if @base_url && !@base_url.empty?

      server = Array(@spec["servers"]).first
      return substitute_server_variables(server) if server.is_a?(Hash) && server["url"]

      if @spec["host"]
        scheme = Array(@spec["schemes"]).first || "https"
        return "#{scheme}://#{@spec['host']}#{@spec['basePath']}"
      end

      if @spec_url&.match?(/\Ahttps?:/)
        uri = URI.parse(@spec_url)
        return "#{uri.scheme}://#{uri.host}#{uri.port && ![80, 443].include?(uri.port) ? ":#{uri.port}" : ""}"
      end

      raise ValidationError, "OpenAPI document does not define a server URL; pass base_url"
    end

    def substitute_server_variables(server)
      variables = Utils.stringify_keys(server["variables"] || {})
      server["url"].gsub(/\{([^}]+)\}/) do
        variable = variables[Regexp.last_match(1)]
        variable.is_a?(Hash) ? variable["default"].to_s : Regexp.last_match(0)
      end
    end

    def join_url(base, path)
      "#{base.to_s.sub(%r{/+\z}, '')}/#{path.to_s.sub(%r{\A/+}, '')}"
    end

    def generated_name(method, path)
      "#{method}_#{path}".gsub(/[^A-Za-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
    end
  end
  OpenApiConverter = OpenAPIConverter
end

