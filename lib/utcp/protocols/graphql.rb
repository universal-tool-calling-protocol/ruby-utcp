# frozen_string_literal: true

module UTCP
  class GraphQLProtocol < HTTPProtocol
    INTROSPECTION_QUERY = <<~GRAPHQL.freeze
      query UTCPIntrospection {
        __schema {
          queryType { name fields { name description args { name description defaultValue type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } }
          mutationType { name fields { name description args { name description defaultValue type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } }
          subscriptionType { name fields { name description args { name description defaultValue type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } }
          types { kind name fields { name type { kind name ofType { kind name ofType { kind name } } } } enumValues { name } }
        }
      }
    GRAPHQL

    def initialize(websocket_factory: nil, **options)
      super(**options)
      @websocket_factory = websocket_factory || lambda do |url, headers, protocol, timeout|
        WebSocketConnection.new(url, headers, protocol, timeout)
      end
    end

    def register_manual(client, template)
      assert_graphql_template!(template)
      result = graphql_request(template, "query" => INTROSPECTION_QUERY, "variables" => {})
      schema = result.dig("data", "__schema")
      raise SerializerValidationError, "GraphQL introspection response does not contain data.__schema" unless schema

      manual = Manual.new(
        utcp_version: VERSION,
        manual_version: "1.0.0",
        info: { "title" => template.name, "version" => "1.0.0" },
        tools: introspection_tools(template, schema)
      )
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register GraphQL manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_graphql_template!(template)
      if template.operation_type == "subscription"
        values = []
        call_subscription(tool_name, tool_args, template) { |value| values << value }
        return values
      end

      args, headers = extract_header_arguments(template, tool_args)
      payload = graphql_payload(tool_name, args, template)
      response = graphql_request(template, payload, headers)
      raise_graphql_errors!(response, tool_name)
      extract_graphql_data(response, template.operation_name || unqualified_name(tool_name))
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("GraphQL tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      if template.operation_type == "subscription"
        call_subscription(tool_name, tool_args, template) { |value| yield value }
      else
        yield call_tool(_client, tool_name, tool_args, template)
      end
    end

    private

    def assert_graphql_template!(template)
      return if template.is_a?(GraphQLCallTemplate)

      raise ValidationError, "GraphQL protocol requires a GraphQLCallTemplate"
    end

    def graphql_request(template, payload, extra_headers = {})
      headers = Utils.stringify_keys(template.headers || {}).merge(Utils.stringify_keys(extra_headers))
      headers["Accept"] ||= "application/json"
      query = {}
      cookies = {}
      sensitive = apply_auth(template.auth, headers, query, cookies)
      if template.auth.is_a?(OAuth2Auth)
        headers["Authorization"] = "Bearer #{oauth_token(template.auth)}"
        sensitive << "Authorization"
      end
      uri = URLSecurity.validate!(append_query(template.url, query), context: "GraphQL request")
      response = perform_request(
        "POST", uri,
        headers: headers,
        cookies: cookies,
        body: payload,
        content_type: "application/json",
        timeout: template.timeout,
        sensitive_headers: sensitive.uniq, max_response_bytes: template.max_response_bytes
      )
      data = JSON.parse(response.body)
      raise_graphql_errors!(data, template.operation_name || template.name)
      data
    rescue JSON::ParserError => error
      raise SerializerValidationError, "Invalid GraphQL JSON response: #{error.message}"
    end

    def introspection_tools(template, schema)
      types = Array(schema["types"]).each_with_object({}) { |type, map| map[type["name"]] = type if type["name"] }
      %w[query mutation subscription].flat_map do |kind|
        root = schema["#{kind}Type"]
        next [] unless root

        Array(root["fields"]).map do |field|
          args = Array(field["args"])
          properties = args.each_with_object({}) do |argument, result|
            result[argument["name"]] = schema_for_type(argument["type"], types).tap do |value|
              value["description"] = argument["description"] if argument["description"]
              value["default"] = argument["defaultValue"] if argument["defaultValue"]
            end
          end
          required = args.select { |argument| argument.dig("type", "kind") == "NON_NULL" }.map { |argument| argument["name"] }
          selection = selection_for(field["type"], types)
          call_template = template.to_h.merge(
            "operation_type" => kind,
            "operation_name" => field["name"],
            "variable_types" => args.each_with_object({}) do |argument, result|
              result[argument["name"]] = graphql_type_name(argument["type"])
            end,
            "selection_set" => selection
          )
          Tool.new(
            name: field["name"],
            description: field["description"].to_s,
            inputs: Utils.compact_hash("type" => "object", "properties" => properties, "required" => required.empty? ? nil : required),
            outputs: schema_for_type(field["type"], types),
            tool_call_template: call_template
          )
        end
      end
    end

    def schema_for_type(type, types)
      return {} unless type

      case type["kind"]
      when "NON_NULL"
        schema_for_type(type["ofType"], types)
      when "LIST"
        { "type" => "array", "items" => schema_for_type(type["ofType"], types) }
      when "SCALAR"
        { "type" => scalar_json_type(type["name"]) }
      when "ENUM"
        values = Array(types.dig(type["name"], "enumValues")).map { |value| value["name"] }
        Utils.compact_hash("type" => "string", "enum" => values.empty? ? nil : values)
      when "OBJECT", "INPUT_OBJECT", "INTERFACE", "UNION"
        { "type" => "object" }
      else
        {}
      end
    end

    def scalar_json_type(name)
      return "integer" if name == "Int"
      return "number" if name == "Float"
      return "boolean" if name == "Boolean"

      "string"
    end

    def graphql_type_name(type)
      return "String" unless type

      case type["kind"]
      when "NON_NULL" then "#{graphql_type_name(type["ofType"])}!"
      when "LIST" then "[#{graphql_type_name(type["ofType"])}]"
      else type["name"] || "String"
      end
    end

    def selection_for(type, types)
      inner = type
      inner = inner["ofType"] while inner && %w[NON_NULL LIST].include?(inner["kind"])
      return nil unless inner && %w[OBJECT INTERFACE UNION].include?(inner["kind"])

      fields = Array(types.dig(inner["name"], "fields")).select do |field|
        child = field["type"]
        child = child["ofType"] while child && child["kind"] == "NON_NULL"
        child && %w[SCALAR ENUM].include?(child["kind"])
      end.map { |field| field["name"] }.first(20)
      fields.empty? ? "__typename" : fields.join(" ")
    end

    def graphql_payload(tool_name, arguments, template)
      return { "query" => template.query, "variables" => arguments } if template.query

      field = template.operation_name || unqualified_name(tool_name)
      variable_types = arguments.each_with_object({}) do |(name, _value), result|
        result[name] = template.variable_types[name] || "String"
      end
      declarations = variable_types.map { |name, type| "$#{name}: #{type}" }.join(", ")
      invocation = variable_types.keys.map { |name| "#{name}: $#{name}" }.join(", ")
      operation_label = "UTCP_#{field.gsub(/[^A-Za-z0-9_]/, "_")}"
      query = +"#{template.operation_type} #{operation_label}"
      query << "(#{declarations})" unless declarations.empty?
      query << " { #{field}"
      query << "(#{invocation})" unless invocation.empty?
      query << " { #{template.selection_set} }" if template.selection_set && !template.selection_set.empty?
      query << " }"
      { "query" => query, "variables" => arguments, "operationName" => operation_label }
    end

    def extract_header_arguments(template, arguments)
      args = Utils.stringify_keys(arguments || {})
      headers = {}
      template.header_fields.each { |field| headers[field] = args.delete(field).to_s if args.key?(field) }
      [args, headers]
    end

    def raise_graphql_errors!(response, tool_name)
      errors = response["errors"] if response.is_a?(Hash)
      return if errors.nil? || errors.empty?

      detail = errors.map { |error| error.is_a?(Hash) ? error["message"] : error.to_s }.join("; ")
      raise ToolCallError.new("GraphQL tool #{tool_name.inspect} returned errors: #{detail}", tool_name: tool_name,
                              response_body: JSON.generate(errors))
    end

    def extract_graphql_data(response, field)
      data = response["data"]
      data.is_a?(Hash) && data.key?(field) ? data[field] : data
    end

    def unqualified_name(tool_name)
      tool_name.to_s.split(".").last
    end

    def call_subscription(tool_name, tool_args, template)
      args, headers = extract_header_arguments(template, tool_args)
      query = {}
      cookies = {}
      apply_auth(template.auth, headers, query, cookies)
      headers["Authorization"] = "Bearer #{oauth_token(template.auth)}" if template.auth.is_a?(OAuth2Auth)
      headers["Cookie"] = cookies.map { |key, value| "#{key}=#{value}" }.join("; ") unless cookies.empty?
      http_uri = URLSecurity.validate!(append_query(template.url, query), context: "GraphQL subscription")
      ws_scheme = http_uri.scheme == "https" ? "wss" : "ws"
      ws_url = http_uri.to_s.sub(/\Ahttps?/, ws_scheme)
      connection = @websocket_factory.call(ws_url, headers, "graphql-transport-ws", template.timeout)
      connection.max_response_bytes = template.max_response_bytes if connection.respond_to?(:max_response_bytes=)
      budget = ResponseByteBudget.new(template.max_response_bytes, "GraphQL subscription")
      identifier = SecureRandom.uuid
      connection.send_text(JSON.generate("type" => "connection_init", "payload" => {}))
      ack = connection.read_message
      budget.consume(ack[1]) if ack
      ack_data = ack && decode_json_or_text(ack[1].force_encoding(Encoding::UTF_8))
      unless ack_data.is_a?(Hash) && ack_data["type"] == "connection_ack"
        raise ToolCallError, "GraphQL subscription did not receive connection_ack"
      end
      connection.send_text(JSON.generate(
        "id" => identifier,
        "type" => "subscribe",
        "payload" => graphql_payload(tool_name, args, template)
      ))
      loop do
        connection.max_response_bytes = budget.remaining if connection.respond_to?(:max_response_bytes=)
        frame = connection.read_message
        break unless frame
        budget.consume(frame[1])
        message = decode_json_or_text(frame[1].force_encoding(Encoding::UTF_8))
        next unless message.is_a?(Hash) && message["id"] == identifier
        break if message["type"] == "complete"
        if message["type"] == "error"
          raise ToolCallError, "GraphQL subscription failed: #{message["payload"].inspect}"
        end
        next unless message["type"] == "next"

        payload = message["payload"] || {}
        raise_graphql_errors!(payload, tool_name)
        yield extract_graphql_data(payload, template.operation_name || unqualified_name(tool_name))
      end
    ensure
      connection.close if defined?(connection) && connection
    end
  end
  GraphqlCommunicationProtocol = GraphQLProtocol
  GraphQLCommunicationProtocol = GraphQLProtocol
end
