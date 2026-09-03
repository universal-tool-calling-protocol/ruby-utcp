# frozen_string_literal: true

require "open3"

module UTCP
  class MCPStdioSession
    def initialize(config, timeout)
      command = config["command"]
      command = command.first if command.is_a?(Array)
      raise ValidationError, "MCP stdio server requires command" if command.to_s.empty?

      args = Array(config["args"]).map(&:to_s)
      environment = Utils.stringify_keys(config["env"] || {}).transform_values(&:to_s)
      options = { pgroup: true }
      options[:chdir] = config["cwd"] || config["workingDir"] if config["cwd"] || config["workingDir"]
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(environment, command.to_s, *args, options)
      @timeout = timeout
      @next_id = 0
      @mutex = Mutex.new
      @stderr_reader = Thread.new { @stderr.read }
    end

    def request(method, params = nil)
      @mutex.synchronize do
        identifier = (@next_id += 1)
        message = { "jsonrpc" => "2.0", "id" => identifier, "method" => method }
        message["params"] = params unless params.nil?
        write_message(message)
        loop do
          response = read_message
          next unless response["id"] == identifier
          raise ToolCallError, "MCP error #{response["error"].inspect}" if response["error"]

          return response["result"]
        end
      end
    end

    def notify(method, params = nil)
      @mutex.synchronize do
        message = { "jsonrpc" => "2.0", "method" => method }
        message["params"] = params unless params.nil?
        write_message(message)
      end
      nil
    end

    def close
      @stdin.close unless @stdin.closed?
      Process.kill("TERM", -@wait_thread.pid) if @wait_thread&.alive?
      @wait_thread.join(1) if @wait_thread
      Process.kill("KILL", -@wait_thread.pid) if @wait_thread&.alive?
    rescue Errno::ESRCH, Errno::EPERM, IOError
      nil
    ensure
      @stdout.close unless @stdout.closed?
      @stderr.close unless @stderr.closed?
      @stderr_reader.kill if @stderr_reader&.alive?
    end

    private

    def write_message(message)
      @stdin.write(JSON.generate(message) + "\n")
      @stdin.flush
    rescue Errno::EPIPE, IOError => error
      raise ToolCallError, "MCP stdio write failed: #{error.message}"
    end

    def read_message
      ready = IO.select([@stdout], nil, nil, @timeout)
      raise TimeoutError, "MCP stdio response timed out" unless ready

      line = @stdout.gets
      raise ToolCallError, "MCP stdio server closed the stream" unless line

      JSON.parse(line)
    rescue JSON::ParserError => error
      raise SerializerValidationError, "Invalid MCP stdio JSON: #{error.message}"
    end
  end

  class MCPHTTPSession
    attr_reader :session_id

    def initialize(config, template, protocol)
      @url = Utils.required_string!(config["url"], "MCP server url")
      @headers = Utils.stringify_keys(config["headers"] || {})
      @template = template
      @protocol = protocol
      @next_id = 0
      @session_id = nil
      @mutex = Mutex.new
    end

    def request(method, params = nil)
      @mutex.synchronize do
        identifier = (@next_id += 1)
        message = { "jsonrpc" => "2.0", "id" => identifier, "method" => method }
        message["params"] = params unless params.nil?
        response = transmit(message)
        raise ToolCallError, "MCP error #{response["error"].inspect}" if response["error"]

        response["result"]
      end
    end

    def notify(method, params = nil)
      @mutex.synchronize do
        message = { "jsonrpc" => "2.0", "method" => method }
        message["params"] = params unless params.nil?
        transmit(message, notification: true)
      end
      nil
    end

    def close
      nil
    end

    private

    def transmit(message, notification: false)
      response = @protocol.send(:mcp_http_request, @url, @headers, @template, message, @session_id)
      @session_id ||= response[:session_id]
      return {} if notification && response[:body].to_s.empty?

      values = response[:content_type].include?("text/event-stream") ? sse_values(response[:body]) : [JSON.parse(response[:body])]
      identifier = message["id"]
      values.find { |value| value.is_a?(Hash) && value["id"] == identifier } || values.last || {}
    rescue JSON::ParserError => error
      raise SerializerValidationError, "Invalid MCP HTTP JSON: #{error.message}"
    end

    def sse_values(body)
      values = []
      parser = SSEParser.new
      parser.feed(body) { |value| values << value }
      parser.finish { |value| values << value }
      values
    end
  end

  class MCPProtocol < HTTPProtocol
    def initialize(session_factory: nil, **options)
      super(**options)
      @session_factory = session_factory
      @sessions = {}
      @resources = {}
      @sessions_mutex = Mutex.new
    end

    def register_manual(client, template)
      assert_mcp_template!(template)
      tools = []
      errors = []
      template.servers.each do |server_name, config|
        begin
          session = session_for(template, server_name, config)
          initialize_session(session, template)
          result = session.request("tools/list", {}) || {}
          Array(result["tools"]).each do |tool|
            tools << Tool.new(
              name: "#{server_name}.#{tool.fetch("name")}",
              description: tool["description"].to_s,
              inputs: tool["inputSchema"] || {},
              outputs: tool["outputSchema"] || {},
              tool_call_template: template
            )
          end
          add_resource_tools(template, server_name, session, tools) if template.register_resources_as_tools
        rescue StandardError => error
          errors << "#{server_name}: #{error.message}"
        end
      end
      manual = Manual.new(utcp_version: VERSION, manual_version: "1.0.0", tools: tools)
      RegisterManualResult.new(
        manual_call_template: template,
        manual: manual,
        success: errors.empty?,
        errors: errors
      )
    rescue StandardError => error
      client.logger.warn("Unable to register MCP manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def deregister_manual(_client, template)
      prefix = "#{template.name}\0"
      sessions = @sessions_mutex.synchronize do
        keys = @sessions.keys.select { |key| key.start_with?(prefix) }
        keys.map { |key| @sessions.delete(key) }
      end
      sessions.each(&:close)
      @resources.delete_if { |key, _value| key.start_with?(prefix) }
      nil
    end

    def call_tool(_client, tool_name, tool_args, template)
      assert_mcp_template!(template)
      server_name, local_name = parse_tool_name(tool_name, template)
      config = template.servers.fetch(server_name)
      session = session_for(template, server_name, config)
      resource_uri = @resources[resource_key(template, server_name, local_name)]
      result = if resource_uri
                 session.request("resources/read", "uri" => resource_uri)
               else
                 session.request("tools/call", "name" => local_name, "arguments" => Utils.stringify_keys(tool_args || {}))
               end
      process_mcp_result(result)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("MCP tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    def mcp_http_request(url, static_headers, template, message, session_id)
      headers = Utils.stringify_keys(static_headers || {})
      headers["Accept"] = "application/json, text/event-stream"
      headers["MCP-Protocol-Version"] = template.protocol_version
      headers["MCP-Session-Id"] = session_id if session_id
      query = {}
      cookies = {}
      sensitive = apply_auth(template.auth, headers, query, cookies)
      if template.auth.is_a?(OAuth2Auth)
        headers["Authorization"] = "Bearer #{oauth_token(template.auth)}"
        sensitive << "Authorization"
      end
      uri = URLSecurity.validate!(append_query(url, query), context: "MCP HTTP")
      response = perform_request(
        "POST", uri,
        headers: headers,
        cookies: cookies,
        body: message,
        content_type: "application/json",
        timeout: template.timeout,
        sensitive_headers: sensitive.uniq
      )
      {
        body: response.body.to_s,
        content_type: response["content-type"].to_s.downcase,
        session_id: response["mcp-session-id"]
      }
    end

    private

    def assert_mcp_template!(template)
      return if template.is_a?(McpCallTemplate)

      raise ValidationError, "MCP protocol requires a McpCallTemplate"
    end

    def session_for(template, server_name, config)
      key = "#{template.name}\0#{server_name}"
      @sessions_mutex.synchronize do
        @sessions[key] ||= if @session_factory
                            @session_factory.call(server_name, config, template)
                          elsif %w[http streamable_http sse].include?(config["transport"].to_s) || config["url"]
                            MCPHTTPSession.new(config, template, self)
                          else
                            MCPStdioSession.new(config, template.timeout)
                          end
      end
    end

    def initialize_session(session, template)
      session.request("initialize", {
        "protocolVersion" => template.protocol_version,
        "capabilities" => {},
        "clientInfo" => { "name" => "ruby-utcp", "version" => VERSION }
      })
      session.notify("notifications/initialized", {})
    end

    def add_resource_tools(template, server_name, session, tools)
      cursor = nil
      loop do
        params = cursor ? { "cursor" => cursor } : {}
        result = session.request("resources/list", params) || {}
        Array(result["resources"]).each do |resource|
          safe_name = resource.fetch("name", resource.fetch("uri")).to_s.gsub(/[^[:alnum:]_]/, "_")
          local_name = "resource_#{safe_name}"
          @resources[resource_key(template, server_name, local_name)] = resource.fetch("uri")
          tools << Tool.new(
            name: "#{server_name}.#{local_name}",
            description: "Read MCP resource: #{resource["description"] || resource["name"] || resource["uri"]}",
            inputs: { "type" => "object", "properties" => {} },
            outputs: { "type" => "object" },
            tool_call_template: template
          )
        end
        cursor = result["nextCursor"]
        break if cursor.nil? || cursor.empty?
      end
    end

    def resource_key(template, server_name, local_name)
      "#{template.name}\0#{server_name}\0#{local_name}"
    end

    def parse_tool_name(tool_name, template)
      parts = tool_name.to_s.split(".")
      parts.shift if parts.first == template.name
      if parts.length >= 2 && template.servers.key?(parts.first)
        [parts.shift, parts.join(".")]
      elsif template.servers.length == 1
        [template.servers.keys.first, parts.join(".")]
      else
        raise ToolCallError, "MCP tool name must include one of the server names: #{template.servers.keys.join(', ')}"
      end
    end

    def process_mcp_result(result)
      return result unless result.is_a?(Hash)
      return result["structuredContent"] if result.key?("structuredContent")
      return result if result.key?("contents")

      content = fetch_content(result["content"])
      return result unless content
      return process_mcp_content(content.first) if content.length == 1

      content.map { |item| process_mcp_content(item) }
    end

    def process_mcp_content(item)
      return item unless item.is_a?(Hash) && item["type"] == "text"

      decode_json_or_text(item["text"].to_s)
    end

    # Keeps the nil-vs-empty distinction explicit without relying on ActiveSupport.
    def fetch_content(value)
      value.is_a?(Array) && !value.empty? ? value : nil
    end
  end
  McpCommunicationProtocol = MCPProtocol
  MCPCommunicationProtocol = MCPProtocol
end
