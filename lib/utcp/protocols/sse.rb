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
      with_collection_timeout(template) do
        call_tool_streaming(client, tool_name, tool_args, template) { |value| values << value }
      end
      values
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      assert_sse_template!(template)
      with_stream_response(template, tool_args || {}, accept: "text/event-stream") do |response|
        parser = SSEParser.new(event_type: template.event_type, max_event_bytes: template.max_event_bytes)
        count = 0
        response.read_body do |chunk|
          parser.feed(chunk) do |event|
            count += 1
            raise ToolCallError, "SSE response exceeds max_response_items" if count > template.max_response_items
            yield event
          end
        end
        parser.finish
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
    def initialize(event_type: nil, max_event_bytes: ResponseLimits::DEFAULT_MAX_EVENT_BYTES)
      @event_type = event_type
      @maximum = Integer(max_event_bytes)
      raise ValidationError, "max_event_bytes must be greater than zero" unless @maximum.positive?
      @buffer = +"".b
      @skip_lf = false
      @first_line = true
      @event_bytes = 0
      @fields = reset_fields
    end

    def feed(chunk)
      bytes = chunk.to_s.b
      offset = 0
      while offset < bytes.bytesize
        if @skip_lf
          @skip_lf = false
          offset += 1 if bytes.getbyte(offset) == 10
          next if offset == bytes.bytesize
        end
        index = bytes.index(/[\r\n]/, offset)
        length = (index || bytes.bytesize) - offset
        @event_bytes += length
        raise ToolCallError, "SSE event exceeds max_event_bytes (#{@maximum})" if @event_bytes > @maximum
        @buffer << bytes.byteslice(offset, length)
        break unless index

        line = @buffer
        @buffer = +"".b
        if @first_line
          line = line.delete_prefix("\xEF\xBB\xBF".b)
          @first_line = false
        end
        @skip_lf = bytes.getbyte(index) == 13
        offset = index + 1
        process_line(line.force_encoding(Encoding::UTF_8)) { |event| yield event }
      end
    end

    def finish
      # EOF is not an event delimiter; discard an unfinished event.
      @buffer.clear
      @fields = reset_fields
      @event_bytes = 0
    end

    private

    def process_line(line)
      if line.empty?
        @event_bytes = 0
        dispatch { |event| yield event }
        return
      end
      return if line.start_with?(":")

      field, value = line.split(":", 2)
      value = value.to_s.sub(/\A /, "")
      case field
      when "data"
        @fields[:has_data] = true
        @fields[:data] << value << "\n"
      when "event" then @fields[:event] = value
      when "id" then @fields[:id] = value unless value.include?("\0")
      when "retry" then @fields[:retry] = Integer(value) rescue nil
      end
    end

    def dispatch
      fields = @fields
      @fields = reset_fields
      return unless fields[:has_data]
      return if @event_type && fields[:event] != @event_type

      payload = fields[:data].delete_suffix("\n")
      value = begin
        JSON.parse(payload)
      rescue JSON::ParserError
        payload
      end
      yield value
    end

    def reset_fields
      { data: +"", has_data: false, event: nil, id: nil, retry: nil }
    end
  end
  SseCommunicationProtocol = SSEProtocol
  SSECommunicationProtocol = SSEProtocol
end
