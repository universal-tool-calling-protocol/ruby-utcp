# frozen_string_literal: true

module UTCP
  class StreamableHTTPProtocol < HTTPProtocol
    include HTTPStreamSupport

    def register_manual(client, template)
      assert_stream_template!(template)
      response = buffered_discovery(template)
      success(template, manual_from_payload(template, response.body, source: "streamable HTTP discovery response"))
    rescue StandardError => error
      client.logger.warn("Unable to register streamable HTTP manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(client, tool_name, tool_args, template)
      chunks = []
      binary = false
      with_collection_timeout(template) do
        call_tool_streaming(client, tool_name, tool_args, template) do |chunk|
          binary ||= chunk.is_a?(String) && chunk.encoding == Encoding::BINARY
          chunks << chunk
        end
      end
      binary && chunks.all? { |chunk| chunk.is_a?(String) } ? chunks.join.b : chunks
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      assert_stream_template!(template)
      count = 0
      emit = lambda do |item|
        count += 1
        raise ToolCallError, "Streamable HTTP response exceeds max_response_items" if count > template.max_response_items
        yield item
      end
      with_stream_response(template, tool_args || {}) do |response|
        content_type = response["content-type"].to_s.downcase
        if content_type.include?("application/x-ndjson") || content_type.include?("application/json-seq")
          separator = content_type.include?("application/json-seq") ? "\x1E" : "\n"
          stream_json_lines(response, template.max_event_bytes, separator, &emit)
        elsif content_type.include?("application/json")
          body = +""
          response.read_body do |chunk|
            check_event_size!(body.bytesize + chunk.bytesize, template.max_event_bytes)
            body << chunk
          end
          emit.call(decode_json_or_text(body)) unless body.empty?
        else
          response.read_body do |chunk|
            bytes = chunk.to_s.b
            offset = 0
            while offset < bytes.bytesize
              size = [template.chunk_size, template.max_event_bytes].min
              emit.call(bytes.byteslice(offset, size))
              offset += size
            end
          end
        end
      end
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("Streamable HTTP tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_stream_template!(template)
      return if template.is_a?(StreamableHttpCallTemplate)

      raise ValidationError, "streamable HTTP protocol requires a StreamableHttpCallTemplate"
    end

    def stream_json_lines(response, maximum, separator = "\n")
      buffer = +"".b
      response.read_body do |chunk|
        bytes = chunk.to_s.b
        offset = 0
        while offset < bytes.bytesize
          index = bytes.index(separator, offset)
          length = (index || bytes.bytesize) - offset
          check_event_size!(buffer.bytesize + length, maximum)
          buffer << bytes.byteslice(offset, length)
          break unless index

          line = buffer.strip
          buffer = +"".b
          yield decode_json_or_text(line.force_encoding(Encoding::UTF_8)) unless line.empty?
          offset = index + 1
        end
      end
      tail = buffer.strip
      yield decode_json_or_text(tail.force_encoding(Encoding::UTF_8)) unless tail.empty?
    end

    def check_event_size!(size, maximum)
      raise ToolCallError, "Streamable HTTP event exceeds max_event_bytes (#{maximum})" if size > maximum
    end
  end
  StreamableHttpCommunicationProtocol = StreamableHTTPProtocol
  StreamableHTTPCommunicationProtocol = StreamableHTTPProtocol
end
