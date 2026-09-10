# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "timeout"

module RubyUTCPAgent
  # OpenRouter-compatible chat completions; no provider-specific gem is needed.
  class LLM
    class Error < StandardError; end
    DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024

    def initialize(api_key:, model:, base_url: DEFAULT_BASE_URL)
      @uri = URI.parse(base_url.sub(%r{/+\z}, "") + "/chat/completions")
      local = %w[localhost 127.0.0.1 ::1].include?(@uri.hostname)
      unless @uri.is_a?(URI::HTTP) && (@uri.scheme == "https" || local) &&
             @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
        raise ArgumentError, "base URL must use HTTPS (HTTP is allowed only for loopback hosts)"
      end
      raise ArgumentError, "set OPENROUTER_API_KEY or LLM_API_KEY" if !local && api_key.to_s.strip.empty?
      raise ArgumentError, "set OPENROUTER_MODEL or pass --model with a tool-capable model ID" if model.to_s.strip.empty?
      raise ArgumentError, "API key must not contain newlines" if api_key.to_s.match?(/[\r\n]/)

      @api_key, @model = api_key.to_s, model
    rescue URI::InvalidURIError => error
      raise ArgumentError, "invalid base URL: #{error.message}"
    end

    def complete(messages:, tools:)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Authorization"] = "Bearer #{@api_key}" unless @api_key.empty?
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate("model" => @model, "messages" => messages, "tools" => tools, "stream" => false)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.open_timeout = 15
      http.read_timeout = 120
      http.write_timeout = 30 if http.respond_to?(:write_timeout=)
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      body = +"".b
      Timeout.timeout(150) do
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise Error, "LLM HTTP #{response.code}; check the endpoint, API key, model access, rate limits, and account credit"
          end
          response.read_body do |chunk|
            raise Error, "LLM response exceeds #{MAX_RESPONSE_BYTES} bytes" if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

            body << chunk
          end
        end
      end
      payload = JSON.parse(body)
      choice = payload.fetch("choices").first
      raise Error, "LLM response has no choices" unless choice.is_a?(Hash)
      unless %w[stop tool_calls].include?(choice["finish_reason"])
        raise Error, "LLM completion did not finish normally: #{choice['finish_reason'].inspect}"
      end
      message = choice.fetch("message")
      raise Error, "LLM response has no assistant message" unless message.is_a?(Hash) && message["role"] == "assistant"

      message
    rescue Error
      raise
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError => error
      raise Error, "invalid chat-completions response: #{error.class}"
    rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => error
      raise Error, "LLM connection failed: #{error.class}"
    end
  end
end
