# frozen_string_literal: true

module UTCP
  class SSEProtocol < HTTPProtocol
    include HTTPStreamSupport

    def register_manual(client, template)
      assert_sse_template!(template)
      response = buffered_discovery(template)
      manual = manual_from_payload(template, response.body, source: "SSE discovery response")
      success(template, manual)
    rescue StandardError => error
      client.logger.warn("Unable to register SSE manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(client, tool_name, tool_args, template)
      values = []
      call_tool_streaming(client, tool_name, tool_args, template) { |value| values << value }
      values
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      assert_sse_template!(template)
      with_stream_response(template, tool_args || {}, accept: "text/event-stream") do |response|
        parser = SSEParser.new(event_type: template.event_type)
        response.read_body do |chunk|
          parser.feed(chunk) { |event| yield event }
        end
        parser.finish { |event| yield event }
      end
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("SSE tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_sse_template!(template)
      return if template.is_a?(SseCallTemplate)

      raise ValidationError, "SSE protocol requires an SseCallTemplate"
    end
  end

  class SSEParser
    def initialize(event_type: nil)
      @event_type = event_type
      @buffer = +""
      @fields = reset_fields
    end

    def feed(chunk)
      @buffer << chunk.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      while (index = @buffer.index("\n"))
        line = @buffer.slice!(0..index).chomp
        process_line(line) { |event| yield event }
      end
    end

    def finish
      process_line(@buffer) { |event| yield event } unless @buffer.empty?
      dispatch { |event| yield event } unless @fields[:data].empty?
      @buffer.clear
    end

    private

    def process_line(line)
      if line.empty?
        dispatch { |event| yield event }
        return
      end
      return if line.start_with?(":")

      field, value = line.split(":", 2)
      value = value.to_s.sub(/\A /, "")
      case field
      when "data" then @fields[:data] << value
      when "event" then @fields[:event] = value
      when "id" then @fields[:id] = value unless value.include?("\0")
      when "retry" then @fields[:retry] = Integer(value) rescue nil
      end
    end

    def dispatch
      fields = @fields
      @fields = reset_fields
      return if fields[:data].empty?
      return if @event_type && fields[:event] != @event_type

      payload = fields[:data].join("\n")
      yield JSON.parse(payload)
    rescue JSON::ParserError
      yield payload
    end

    def reset_fields
      { data: [], event: nil, id: nil, retry: nil }
    end
  end
  SseCommunicationProtocol = SSEProtocol
  SSECommunicationProtocol = SSEProtocol
end
