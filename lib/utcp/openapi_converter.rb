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
        path_item = dereference(path_item)
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
      parameters = (Array(path_item["parameters"]) + Array(operation["parameters"])).each_with_object({}) do |value, result|
        parameter = dereference(value)
        next unless parameter.is_a?(Hash)

        result[[parameter["in"], parameter["name"]]] = parameter
      end.values
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
          properties[body_field] = parameter["schema"] || {}
          required << body_field if parameter["required"]
        else
          properties[name] = parameter["schema"] || parameter_schema(parameter)
          required << name if parameter["required"] || parameter["in"] == "path"
          header_fields << name if parameter["in"] == "header"
        end
      end

      request_body = dereference(operation["requestBody"])
      if request_body.is_a?(Hash)
        content_type, media = Array(request_body["content"]).first
        if media.is_a?(Hash)
          properties[body_field] = media["schema"] || {}
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
        inputs: resolve_schema(input_schema),
        outputs: response_schema(operation),
        tags: Array(operation["tags"]),
        tool_call_template: HttpCallTemplate.new(
          name: tool_name,
          url: join_url(resolve_base_url(operation, path_item), path),
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

    def reference_value(reference)
      unless reference.is_a?(String) && reference.start_with?("#/")
        raise ValidationError, "Only local OpenAPI references are supported: #{reference.inspect}"
      end

      reference.delete_prefix("#/").split("/").reduce(@spec) do |node, component|
        key = component.gsub("~1", "/").gsub("~0", "~")
        unless node.is_a?(Hash) && node.key?(key)
          raise ValidationError, "Unresolved OpenAPI reference: #{reference}"
        end
        node[key]
      end
    end

    def dereference(value, seen = [])
      return value unless value.is_a?(Hash) && value.key?("$ref")

      reference = value["$ref"]
      raise ValidationError, "Circular OpenAPI object reference: #{reference}" if seen.include?(reference)

      dereference(reference_value(reference), seen + [reference])
    end

    def resolve_schema(schema)
      # Bundle references in the exported schema so recursive models remain usable
      # after the original OpenAPI document is no longer available.
      definitions = {}
      references = {}
      reserved_names = schema.is_a?(Hash) && schema["$defs"].is_a?(Hash) ? schema["$defs"].keys : []
      transform = lambda do |value|
        return value unless value.is_a?(Hash)

        if value.key?("$ref")
          reference = value["$ref"]
          unless references.key?(reference)
            name = "utcp_ref_#{references.length + 1}"
            name = "_#{name}" while reserved_names.include?(name) || references.value?(name)
            references[reference] = name
            definitions[name] = transform.call(reference_value(reference))
          end
          return { "$ref" => "#/$defs/#{references.fetch(reference)}" }
        end

        value.each_with_object({}) do |(key, item), result|
          result[key] = case key
                        when "properties", "patternProperties", "definitions", "$defs", "dependentSchemas"
                          item.is_a?(Hash) ? item.transform_values { |child| transform.call(child) } : item
                        when "items", "additionalItems", "additionalProperties", "contains", "not", "if", "then", "else", "propertyNames"
                          item.is_a?(Array) ? item.map { |child| transform.call(child) } : transform.call(item)
                        when "allOf", "anyOf", "oneOf", "prefixItems"
                          Array(item).map { |child| transform.call(child) }
                        else Utils.deep_copy(item)
                        end
        end
      end
      result = transform.call(schema || {})
      result["$defs"] = (result["$defs"] || {}).merge(definitions) unless definitions.empty?
      result
    end

    def response_schema(operation)
      responses = operation["responses"]
      return {} unless responses.is_a?(Hash)

      _status, response = responses.find { |status, _value| status.to_s.match?(/\A2\d\d\z/) } || responses.first
      response = dereference(response)
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

    def resolve_base_url(operation = {}, path_item = {})
      return absolute_server_url(@base_url) if @base_url && !@base_url.empty?

      servers = [operation["servers"], path_item["servers"], @spec["servers"]].find { |value| value.is_a?(Array) && !value.empty? }
      server = Array(servers).first
      return absolute_server_url(substitute_server_variables(server)) if server.is_a?(Hash) && server["url"]

      if @spec["host"]
        scheme = Array(@spec["schemes"]).first || "https"
        return "#{scheme}://#{@spec['host']}#{@spec['basePath']}"
      end

      if @spec_url&.match?(/\Ahttps?:/)
        return absolute_server_url("/")
      end

      raise ValidationError, "OpenAPI document does not define a server URL; pass base_url"
    end

    def absolute_server_url(url)
      uri = URI.parse(url)
      uri = URI.join(@spec_url, url) if !uri.absolute? && @spec_url
      unless %w[http https].include?(uri.scheme) && uri.host
        raise ValidationError, "OpenAPI server URL must resolve to HTTP(S); pass an absolute spec_url or base_url"
      end
      uri.to_s
    rescue URI::InvalidURIError => error
      raise ValidationError, "Invalid OpenAPI server URL: #{error.message}"
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
