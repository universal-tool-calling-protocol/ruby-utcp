# frozen_string_literal: true

require "open3"

module UTCP
  class MCPStdioSession
    MAX_MESSAGE_BYTES = 16 * 1024 * 1024
    MAX_STDERR_BYTES = 64 * 1024

    def initialize(config, timeout, max_message_bytes: MAX_MESSAGE_BYTES, max_response_bytes: nil)
      @timeout = Float(timeout)
      raise ValidationError, "MCP timeout must be finite and greater than zero" unless @timeout.finite? && @timeout.positive?

      @max_message_bytes = Integer(max_message_bytes)
      raise ValidationError, "MCP message limit must be greater than zero" unless @max_message_bytes.positive?
      @max_response_bytes = max_response_bytes.nil? ? @max_message_bytes : Integer(max_response_bytes)
      raise ValidationError, "MCP response limit must be greater than zero" unless @max_response_bytes.positive?

      command = config["command"]
      command = command.first if command.is_a?(Array)
      raise ValidationError, "MCP stdio server requires command" if command.to_s.empty?

      args = Array(config["args"]).map(&:to_s)
      environment = Utils.stringify_keys(config["env"] || {}).transform_values(&:to_s)
      options = { pgroup: true }
      options[:chdir] = config["cwd"] || config["workingDir"] if config["cwd"] || config["workingDir"]
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(environment, command.to_s, *args, options)
      @stdin.binmode
      @stdout.binmode
      @stderr.binmode
      @next_id = 0
      @mutex = Mutex.new
      @read_buffer = +"".b
      @stderr_buffer = +"".b
      @stderr_mutex = Mutex.new
      @stderr_reader = Thread.new { drain_stderr }
    end

    def request(method, params = nil)
      @mutex.synchronize do
        deadline = monotonic_now + @timeout
        identifier = (@next_id += 1)
        message = { "jsonrpc" => "2.0", "id" => identifier, "method" => method }
        message["params"] = params unless params.nil?
        write_message(message, deadline)
        budget = ResponseByteBudget.new(@max_response_bytes, "MCP stdio")
        loop do
          response = read_message(deadline, budget)
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
        write_message(message, monotonic_now + @timeout)
      end
      nil
    end

    def close
      @stdin.close unless @stdin.closed?
      Process.kill("TERM", -@wait_thread.pid) if @wait_thread&.alive?
      @wait_thread.join(1) if @wait_thread
      Process.kill("KILL", -@wait_thread.pid) if @wait_thread&.alive?
      @wait_thread.join(1) if @wait_thread
    rescue Errno::ESRCH, Errno::EPERM, IOError
      nil
    ensure
      @stdout.close unless @stdout.closed?
      @stderr_reader.join(1) if @stderr_reader
      @stderr.close unless @stderr.closed?
      @stderr_reader.kill if @stderr_reader&.alive?
    end

    def stderr_output
      @stderr_mutex.synchronize { @stderr_buffer.dup }
    end

    private

    def write_message(message, deadline)
      data = (JSON.generate(message) + "\n").b
      raise SerializerValidationError, "MCP stdio message exceeds #{@max_message_bytes} bytes" if data.bytesize > @max_message_bytes

      offset = 0
      while offset < data.bytesize
        remaining_time(deadline)
        written = @stdin.write_nonblock(data.byteslice(offset, 4096), exception: false)
        if written == :wait_writable
          wait_for_io(deadline, writable: true)
        else
          offset += written
        end
      end
    rescue Errno::EPIPE, IOError => error
      raise ToolCallError, "MCP stdio write failed: #{error.message}"
    end

    def read_message(deadline, budget = ResponseByteBudget.new(@max_response_bytes, "MCP stdio"))
      loop do
        remaining_time(deadline)
        if (index = @read_buffer.index("\n"))
          bytes = @read_buffer.slice!(0, index + 1)
          budget.consume(bytes)
          response = JSON.parse(bytes)
          raise SerializerValidationError, "MCP stdio response must be an object" unless response.is_a?(Hash)

          return response
        end
        if @read_buffer.bytesize >= budget.remaining
          raise SerializerValidationError, "MCP stdio message exceeds #{@max_response_bytes} bytes (max_response_bytes)"
        end

        chunk = @stdout.read_nonblock([4096, budget.remaining - @read_buffer.bytesize].min, exception: false)
        case chunk
        when :wait_readable then wait_for_io(deadline)
        when nil then raise ToolCallError, "MCP stdio server closed the stream"
        else @read_buffer << chunk
        end
      end
    rescue JSON::ParserError => error
      raise SerializerValidationError, "Invalid MCP stdio JSON: #{error.message}"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining_time(deadline)
      remaining = deadline - monotonic_now
      raise TimeoutError, "MCP stdio request timed out" unless remaining.positive?

      remaining
    end

    def wait_for_io(deadline, writable: false)
      readers, writers = writable ? [nil, [@stdin]] : [[@stdout], nil]
      ready = IO.select(readers, writers, nil, remaining_time(deadline))
      raise TimeoutError, "MCP stdio request timed out" unless ready
    end

    def drain_stderr
      loop do
        chunk = @stderr.readpartial(4096)
        @stderr_mutex.synchronize do
          @stderr_buffer << chunk
          if @stderr_buffer.bytesize > MAX_STDERR_BYTES
            @stderr_buffer = @stderr_buffer.byteslice(-MAX_STDERR_BYTES, MAX_STDERR_BYTES)
          end
        end
      end
    rescue EOFError, IOError
      nil
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
      parser.finish
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
      budget = ResponseByteBudget.new(template.max_response_bytes, "MCP discovery")
      template.servers.each do |server_name, config|
        begin
          session = session_for(client, template, server_name, config)
          each_list_item(session, "tools/list", "tools", budget) do |tool|
            tools << Tool.new(
              name: "#{server_name}.#{tool.fetch("name")}",
              description: tool["description"].to_s,
              inputs: tool["inputSchema"] || {},
              outputs: tool["outputSchema"] || {},
              tool_call_template: template
            )
          end
          add_resource_tools(client, template, server_name, session, tools, budget) if template.register_resources_as_tools
        rescue StandardError => error
          errors << "#{server_name}: #{error.message}"
        end
      end
      deregister_manual(client, template) unless errors.empty?
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

    def deregister_manual(client, template)
      sessions = @sessions_mutex.synchronize do
        keys = @sessions.keys.select { |owner, name, _server| owner.equal?(client) && name == template.name }
        @resources.delete_if { |(owner, name, _server, _resource), _value| owner.equal?(client) && name == template.name }
        keys.map { |key| @sessions.delete(key) }
      end
      sessions.each(&:close)
      nil
    end

    def call_tool(client, tool_name, tool_args, template)
      assert_mcp_template!(template)
      server_name, local_name = parse_tool_name(tool_name, template)
      config = template.servers.fetch(server_name)
      session = session_for(client, template, server_name, config)
      resource_uri = @sessions_mutex.synchronize { @resources[resource_key(client, template, server_name, local_name)] }
      result = if resource_uri
                 session.request("resources/read", "uri" => resource_uri)
               else
                 session.request("tools/call", "name" => local_name, "arguments" => Utils.stringify_keys(tool_args || {}))
               end
      ResponseByteBudget.new(template.max_response_bytes, "MCP").consume_value(result)
      process_mcp_result(result, tool_name: tool_name)
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
      sensitive << "MCP-Session-Id"
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
        sensitive_headers: sensitive.uniq, max_response_bytes: template.max_response_bytes
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

    def session_for(client, template, server_name, config)
      http_transport = %w[http streamable_http sse].include?(config["transport"].to_s) || config["url"]
      assert_no_auth!(template, context: "MCP stdio") unless http_transport || @session_factory
      # A session belongs to the credentials and endpoint used to initialize it.
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([
        config, template.auth&.to_h, template.protocol_version, template.timeout, template.max_response_bytes
      ]))
      key = [client, template.name, server_name, fingerprint]
      @sessions_mutex.synchronize do
        return @sessions[key] if @sessions.key?(key)

        snapshot = McpCallTemplate.from_h(Utils.deep_copy(template.to_h))
        server_config = snapshot.servers.fetch(server_name)
        session = if @session_factory
                    @session_factory.call(server_name, server_config, snapshot)
                  elsif http_transport
                    MCPHTTPSession.new(server_config, snapshot, self)
                  else
                    MCPStdioSession.new(server_config, snapshot.timeout, max_response_bytes: snapshot.max_response_bytes)
                  end
        begin
          initialize_session(session, snapshot)
        rescue StandardError
          session.close
          raise
        end
        @sessions[key] = session
      end
    end

    def initialize_session(session, template)
      response = session.request("initialize", {
        "protocolVersion" => template.protocol_version,
        "capabilities" => {},
        "clientInfo" => { "name" => "ruby-utcp", "version" => VERSION }
      })
      ResponseByteBudget.new(template.max_response_bytes, "MCP initialization").consume_value(response)
      session.notify("notifications/initialized", {})
    end

    def each_list_item(session, method, collection, budget)
      cursor = nil
      seen = {}
      loop do
        params = cursor.nil? ? {} : { "cursor" => cursor }
        result = Utils.hash!(session.request(method, params) || {}, "MCP #{method} result")
        budget.consume_value(result)
        Utils.array!(result.fetch(collection, []), "MCP #{collection}").each { |item| yield item }
        cursor = result["nextCursor"]
        break if cursor.nil?
        unless cursor.is_a?(String) && !seen.key?(cursor)
          raise SerializerValidationError, "MCP #{method} returned an invalid or repeated cursor"
        end

        seen[cursor] = true
      end
    end

    def add_resource_tools(client, template, server_name, session, tools, budget)
      each_list_item(session, "resources/list", "resources", budget) do |resource|
        safe_name = resource.fetch("name", resource.fetch("uri")).to_s.gsub(/[^[:alnum:]_]/, "_")
        local_name = "resource_#{safe_name}"
        @sessions_mutex.synchronize do
          @resources[resource_key(client, template, server_name, local_name)] = resource.fetch("uri")
        end
        tools << Tool.new(
          name: "#{server_name}.#{local_name}",
          description: "Read MCP resource: #{resource["description"] || resource["name"] || resource["uri"]}",
          inputs: { "type" => "object", "properties" => {} },
          outputs: { "type" => "object" },
          tool_call_template: template
        )
      end
    end

    def resource_key(client, template, server_name, local_name)
      [client, template.name, server_name, local_name]
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

    def process_mcp_result(result, tool_name: nil)
      return result unless result.is_a?(Hash)
      if result["isError"]
        details = Array(result["content"]).select { |item| item.is_a?(Hash) && item["type"] == "text" }
                                          .map { |item| item["text"].to_s }.join("\n")
        message = "MCP tool #{tool_name.inspect} failed"
        message += ": #{details}" unless details.empty?
        raise ToolCallError.new(message, tool_name: tool_name, response_body: Utils.deep_copy(result))
      end
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
