# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
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
    class RequestDeadlineExceeded < StandardError; end

    DEFAULT_MODEL = "inception/mercury-2.5"
    DEFAULT_MAX_TOKENS = 4096
    DEFAULT_REQUEST_TIMEOUT = 60
    PROGRESS_INTERVAL = 5
    ENDPOINT = URI("https://openrouter.ai/api/v1/chat/completions")
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    def initialize(api_key:, model: DEFAULT_MODEL, max_tokens: DEFAULT_MAX_TOKENS,
                   request_timeout: DEFAULT_REQUEST_TIMEOUT, log: nil, sleeper: Kernel.method(:sleep))
      raise Error, "Set OPENROUTER_API_KEY to your OpenRouter API key" if api_key.to_s.strip.empty?
      raise Error, "Provide a nonempty OpenRouter model ID" unless model.is_a?(String) && !model.strip.empty?
      raise Error, "max_tokens must be positive" unless max_tokens.is_a?(Integer) && max_tokens.positive?
      unless request_timeout.is_a?(Numeric) && request_timeout.positive? && request_timeout.to_f.finite?
        raise Error, "request_timeout must be a finite positive number"
      end

      @api_key = api_key
      @model = model
      @max_tokens = max_tokens
      @request_timeout = request_timeout
      @log = log
      @sleeper = sleeper
    end

    def close
      http = @http
      @http = nil
      http.finish if http && http.started?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    def complete(messages:, tools: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = with_progress do
        # Net::HTTP read_timeout limits each read. This deadline also covers
        # steadily arriving bytes, connection setup, and every retry/backoff.
        Timeout.timeout(@request_timeout, RequestDeadlineExceeded) do
          perform_completion(messages: messages, tools: tools)
        end
      end
      progress("Model response received after #{format('%.1f', elapsed_since(started))}s")
      result
    rescue RequestDeadlineExceeded
      close
      raise Error, "OpenRouter request exceeded #{@request_timeout}s, including retries. " \
                   "No program from this request was executed. Use a smaller --max-tokens value, " \
                   "try another model, or increase --request-timeout"
    rescue Interrupt
      close
      raise
    end

    private

    def perform_completion(messages:, tools:)
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
          delay = [delay, 30].min
          progress("OpenRouter returned #{error.code}; retry #{attempt + 1}/2 in #{delay}s")
          @sleeper.call(delay)
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

    def with_progress
      return yield unless @log

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      progress("Waiting for #{@model} (#{@max_tokens} output tokens max, #{@request_timeout}s request deadline)")
      lock = Mutex.new
      signal = ConditionVariable.new
      finished = false
      reporter = Thread.new do
        lock.synchronize do
          until finished
            signal.wait(lock, PROGRESS_INTERVAL)
            break if finished

            progress("Still waiting for model response (#{elapsed_since(started).to_i}s elapsed)")
          end
        end
      end
      yield
    ensure
      if reporter
        lock.synchronize { finished = true; signal.signal }
        reporter.join
      end
    end

    def elapsed_since(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def progress(message)
      return unless @log

      @log.puts(message)
      @log.flush
    end

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
      unless @http
        @http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        @http.use_ssl = true
        @http.open_timeout = [10, @request_timeout].min
        @http.read_timeout = @request_timeout
        @http.write_timeout = @request_timeout if @http.respond_to?(:write_timeout=)
        @http.keep_alive_timeout = 120
      end
      @http.start unless @http.started?
      @http.request(request)
    rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
      close
      raise
    end
  end
end
