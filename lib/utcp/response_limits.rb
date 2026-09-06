# frozen_string_literal: true

require "timeout"

module UTCP
  # Ruby extension for network transports; CLI, file and text are excluded.
  module ResponseLimits
    DEFAULT_MAX_RESPONSE_BYTES = 100 * 1024 * 1024
    DEFAULT_MAX_EVENT_BYTES = 1024 * 1024
    DEFAULT_MAX_RESPONSE_ITEMS = 10_000

    attr_accessor :max_response_bytes

    def initialize(max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES, **options)
      super(**options)
      @max_response_bytes = positive_limit(max_response_bytes, "max_response_bytes")
    end

    def to_h
      super.merge("max_response_bytes" => max_response_bytes)
    end

    private

    def positive_limit(value, name)
      result = Integer(value)
      raise ValidationError.new("must be greater than zero", path: name) unless result.positive?
      result
    end
  end

  module HTTPResponseLimits
    include ResponseLimits
    attr_accessor :max_event_bytes, :max_response_items, :total_timeout

    def initialize(max_event_bytes: DEFAULT_MAX_EVENT_BYTES,
                   max_response_items: DEFAULT_MAX_RESPONSE_ITEMS, total_timeout: nil, **options)
      super(**options)
      @max_event_bytes = positive_limit(max_event_bytes, "max_event_bytes")
      @max_response_items = positive_limit(max_response_items, "max_response_items")
      @total_timeout = total_timeout.nil? ? nil : Float(total_timeout)
      if @total_timeout && (!@total_timeout.finite? || !@total_timeout.positive?)
        raise ValidationError.new("must be finite and greater than zero", path: "total_timeout")
      end
    end

    def to_h
      super.merge("max_event_bytes" => max_event_bytes,
                  "max_response_items" => max_response_items).tap do |value|
        value["total_timeout"] = total_timeout if total_timeout
      end
    end

  end

  class ResponseByteBudget
    attr_reader :remaining

    def initialize(maximum, context = "Transport")
      @remaining = maximum
      @context = context
    end

    def consume(bytes)
      @remaining -= bytes.to_s.bytesize
      raise ToolCallError, "#{@context} response exceeds max_response_bytes" if @remaining.negative?
      bytes
    end

    def consume_value(value)
      consume(value.is_a?(String) ? value : JSON.generate(value))
      value
    end
  end

  # Count decoded bytes before a parser or an accumulating caller receives them.
  class LimitedHTTPResponse
    def initialize(response, maximum)
      @response = response
      @maximum = maximum
      @bytes = 0
    end

    def code
      @response.code
    end

    def [](name)
      @response[name]
    end

    def read_body
      consume = lambda do |chunk|
        @bytes += chunk.to_s.bytesize
        raise ToolCallError, "HTTP response exceeds max_response_bytes (#{@maximum})" if @bytes > @maximum
        yield chunk
      end
      if @response.respond_to?(:read_body)
        @response.read_body { |chunk| consume.call(chunk) }
      else
        consume.call(@response.body) unless @response.body.nil?
      end
    end

    def body
      result = nil
      read_body do |chunk|
        result ||= +"".b
        result << chunk.to_s.b
      end
      result
    end
  end
end
