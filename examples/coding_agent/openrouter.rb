# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module CodingAgent
  class Error < StandardError; end
  class InvalidResponseError < Error; end

  class APIError < Error
    attr_reader :code

    def initialize(message, code: nil)
      super(message)
      @code = code
    end
  end

  class OpenRouter
    DEFAULT_MODEL = "inclusionai/ling-3.0-flash"
    DEFAULT_MAX_TOKENS = 16_384
    ENDPOINT = URI("https://openrouter.ai/api/v1/chat/completions")
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    def initialize(api_key:, model: DEFAULT_MODEL, max_tokens: DEFAULT_MAX_TOKENS, sleeper: Kernel.method(:sleep))
      raise Error, "Set OPENROUTER_API_KEY to your OpenRouter API key" if api_key.to_s.strip.empty?
      raise Error, "Provide a nonempty OpenRouter model ID" unless model.is_a?(String) && !model.strip.empty?
      raise Error, "max_tokens must be positive" unless max_tokens.is_a?(Integer) && max_tokens.positive?

      @api_key = api_key
      @model = model
      @max_tokens = max_tokens
      @sleeper = sleeper
    end

    def complete(messages:, tools: nil)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["X-OpenRouter-Title"] = "ruby-utcp coding agent example"
      payload = {
        model: @model, messages: messages,
        max_tokens: @max_tokens, stream: false,
        provider: { require_parameters: true }
      }
      if tools && !tools.empty?
        payload[:tools] = tools
        payload[:tool_choice] = "auto"
      end
      request.body = JSON.generate(payload)

      data = nil
      3.times do |attempt|
        response = request_completion(request)
        invalid_json = false
        begin
          data = JSON.parse(response.body)
        rescue JSON::ParserError
          data = nil
          invalid_json = true
        end

        # Once generation has started, OpenRouter can report a provider failure
        # in the JSON body even though the HTTP status is 200.
        error = response_error(response, data)
        if error && RETRYABLE_STATUSES.include?(error.code) && attempt < 2
          retry_after = response["Retry-After"].to_s
          delay = retry_after.match?(/\A\d+\z/) ? retry_after.to_i : 2**(attempt + 1)
          @sleeper.call([delay, 30].min)
          next
        end
        raise error if error
        raise InvalidResponseError, "OpenRouter returned invalid or incomplete JSON" if invalid_json

        break
      end

      choice = data.is_a?(Hash) && data["choices"].is_a?(Array) && data["choices"].first
      if choice.is_a?(Hash) && choice["finish_reason"] == "length"
        raise InvalidResponseError, "Model output was truncated at the #{@max_tokens}-token output limit"
      end
      unless choice.is_a?(Hash) && choice["message"].is_a?(Hash) && choice["message"]["role"] == "assistant"
        raise Error, "OpenRouter returned no assistant message"
      end

      # Preserve reasoning_details and tool-call metadata for subsequent turns.
      choice["message"]
    rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => error
      raise Error, "OpenRouter connection failed (#{error.class}); try again later"
    end

    private

    def response_error(response, data)
      status = response.code.to_i
      body_error = data.is_a?(Hash) && data["error"]
      return nil if (200..299).cover?(status) && !body_error

      detail = body_error.is_a?(Hash) ? body_error : {}
      code = detail["code"] || ((200..299).cover?(status) ? nil : status)
      code = code.to_i if code.to_s.match?(/\A\d+\z/)
      metadata = detail["metadata"].is_a?(Hash) ? detail["metadata"] : {}
      prefix = (200..299).cover?(status) ? "OpenRouter API error #{code} (HTTP #{status})" : "OpenRouter HTTP #{status}"
      context = {
        "model" => @model, "provider" => metadata["provider_name"] || (data.is_a?(Hash) && data["provider"]),
        "type" => metadata["error_type"], "request" => data.is_a?(Hash) && data["id"]
      }.select { |_key, value| value && !value.to_s.empty? }
      reason = detail["message"] || (body_error.is_a?(String) && body_error)
      parts = [prefix, reason, error_hint(code), context.map { |key, value| "#{key}=#{value}" }.join(", ")]
      # Do not dump raw provider payloads or echo our authorization credential.
      message = parts.select { |part| part && !part.to_s.empty? }.map do |part|
        part.to_s.gsub(@api_key, "[REDACTED]")[0, 1200]
      end.join(". ")
      APIError.new(message, code: code)
    end

    def error_hint(code)
      case code
      when 400 then "Check model limits and request parameters"
      when 401, 403 then "Check OPENROUTER_API_KEY and your OpenRouter account settings"
      when 402 then "Insufficient credits. Check your OpenRouter balance or account spending limit"
      when 404 then "No matching endpoint. Check the model ID and account provider settings"
      when 429 then "Model quota or rate limit reached. Try again later or select another model"
      else "Check OpenRouter availability and your model selection"
      end
    end

    def request_completion(request)
      Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
        http.request(request)
      end
    end
  end
end
