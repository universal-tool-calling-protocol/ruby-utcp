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
      call_tool_streaming(client, tool_name, tool_args, template) do |chunk|
        binary ||= chunk.is_a?(String) && chunk.encoding == Encoding::BINARY
        chunks << chunk
      end
      binary && chunks.all? { |chunk| chunk.is_a?(String) } ? chunks.join.b : chunks
    end

    def call_tool_streaming(_client, tool_name, tool_args, template)
      return enum_for(__method__, _client, tool_name, tool_args, template) unless block_given?

      assert_stream_template!(template)
      with_stream_response(template, tool_args || {}) do |response|
        content_type = response["content-type"].to_s.downcase
        if content_type.include?("application/x-ndjson") || content_type.include?("application/json-seq")
          stream_json_lines(response) { |item| yield item }
        elsif content_type.include?("application/json")
          body = +""
          response.read_body { |chunk| body << chunk }
          yield decode_json_or_text(body) unless body.empty?
        else
          response.read_body do |chunk|
            bytes = chunk.to_s.b
            offset = 0
            while offset < bytes.bytesize
              yield bytes.byteslice(offset, template.chunk_size)
              offset += template.chunk_size
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

    def stream_json_lines(response)
      buffer = +""
      response.read_body do |chunk|
        buffer << chunk.to_s
        while (index = buffer.index("\n"))
          line = buffer.slice!(0..index).strip.sub(/\A\x1E/, "")
          yield decode_json_or_text(line) unless line.empty?
        end
      end
      tail = buffer.strip.sub(/\A\x1E/, "")
      yield decode_json_or_text(tail) unless tail.empty?
    end
  end
  StreamableHttpCommunicationProtocol = StreamableHTTPProtocol
  StreamableHTTPCommunicationProtocol = StreamableHTTPProtocol
end
