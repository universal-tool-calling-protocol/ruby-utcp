# frozen_string_literal: true

require "json"
require "socket"

module UTCP
  module SocketSupport
    private

    def socket_timeout_seconds(template)
      Float(template.timeout) / 1000.0
    end

    def format_socket_message(template, arguments)
      args = Utils.stringify_keys(arguments || {})
      return JSON.generate(args) if template.request_data_format == "json"

      if template.request_data_template && !template.request_data_template.empty?
        substitute_message_template(template.request_data_template, args)
      else
        args.values.map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join(" ")
      end
    end

    def decode_socket_payload(payload, encoding)
      return payload.b if encoding.nil?

      payload.dup.force_encoding(encoding).encode(Encoding::UTF_8)
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError,
           ArgumentError => error
      raise ToolCallError, "Unable to decode socket response as #{encoding}: #{error.message}"
    end

    def escaped_delimiter(value, interpret)
      return value.to_s.b unless interpret

      value.to_s.gsub(/\\(?:x([0-9A-Fa-f]{2})|([nrt0\\]))/) do
        if Regexp.last_match(1)
          Regexp.last_match(1).to_i(16).chr
        else
          { "n" => "\n", "r" => "\r", "t" => "\t", "0" => "\0", "\\" => "\\" }.fetch(Regexp.last_match(2))
        end
      end.b
    end

    def wait_readable!(io, deadline, label)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise TimeoutError, "#{label} timed out" unless remaining.positive? && IO.select([io], nil, nil, remaining)
    end
  end
end
