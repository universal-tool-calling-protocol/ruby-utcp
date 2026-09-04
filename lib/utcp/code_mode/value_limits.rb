# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      private

      def preflight_binary_size!(left, operator, right)
        if operator == :** && right.is_a?(Integer)
          bases = left.is_a?(Rational) ? [left.numerator, left.denominator] : [left]
          bases.each { |base| preflight_integer_power!(base, right) if base.is_a?(Integer) }
        elsif operator == :* && left.is_a?(Integer) && right.is_a?(Integer)
          if !left.zero? && !right.zero? && left.abs.bit_length + right.abs.bit_length > MAX_INTEGER_BITS
            raise CodeModeLimitError, "Integer product exceeds #{MAX_VALUE_BYTES} bytes"
          end
        elsif operator == :+ && left.is_a?(String) && right.is_a?(String)
          raise CodeModeLimitError, "String result exceeds #{MAX_VALUE_BYTES} bytes" if left.bytesize + right.bytesize > MAX_VALUE_BYTES
        elsif operator == :+ && left.is_a?(Array) && right.is_a?(Array)
          raise CodeModeLimitError, "Collection result exceeds #{MAX_VALUE_ITEMS} items" if left.length + right.length > MAX_VALUE_ITEMS
        elsif operator == :* && right.is_a?(Integer) && (left.is_a?(String) || left.is_a?(Array))
          size = left.is_a?(String) ? left.bytesize : left.length
          limit = left.is_a?(String) ? MAX_VALUE_BYTES : MAX_VALUE_ITEMS
          raise CodeModeLimitError, "Repeated value exceeds Code Mode limits" if right.positive? && size > limit / right
        end
      end

      def preflight_integer_power!(base, exponent)
        magnitude = base.abs
        return if magnitude <= 1 || exponent.zero?

        # Use an upper bound without constructing the potentially enormous result.
        bits = magnitude.bit_length
        bits -= 1 if (magnitude & (magnitude - 1)).zero?
        if exponent.abs > (MAX_INTEGER_BITS - 1) / bits
          raise CodeModeLimitError, "Integer power exceeds #{MAX_VALUE_BYTES} bytes"
        end
      end

      def numeric_bytes(value)
        case value
        when Integer then [(value.abs.bit_length + 7) / 8, 1].max
        when Rational then numeric_bytes(value.numerator) + numeric_bytes(value.denominator)
        when Complex then numeric_bytes(value.real) + numeric_bytes(value.imaginary)
        when Float
          raise CodeModeLimitError, "Numeric result must be finite" unless value.finite?
          8
        else value.to_s.bytesize
        end
      end

      def bounded_value!(value)
        if value.is_a?(Numeric) && numeric_bytes(value) > MAX_VALUE_BYTES
          raise CodeModeLimitError, "Numeric result exceeds #{MAX_VALUE_BYTES} bytes"
        end
        if value.is_a?(String) && value.bytesize > MAX_VALUE_BYTES
          raise CodeModeLimitError, "String result exceeds #{MAX_VALUE_BYTES} bytes"
        end
        if (value.is_a?(Array) || value.is_a?(Hash)) && value.length > MAX_VALUE_ITEMS
          raise CodeModeLimitError, "Collection result exceeds #{MAX_VALUE_ITEMS} items"
        end
        value
      end

      def safe_tool_value(value, depth = 0, budget = { items: MAX_VALUE_ITEMS, bytes: MAX_VALUE_BYTES })
        raise CodeModeLimitError, "Tool result nesting is too deep" if depth > 64
        budget[:items] -= 1
        raise CodeModeLimitError, "Tool result contains too many values" if budget[:items].negative?

        case value
        when String
          budget[:bytes] -= value.bytesize
          raise CodeModeLimitError, "Tool result contains too much string data" if budget[:bytes].negative?
          value.dup
        when Numeric
          budget[:bytes] -= numeric_bytes(value)
          raise CodeModeLimitError, "Tool result contains too much numeric data" if budget[:bytes].negative?
          value
        when nil, true, false
          value
        when Array
          value.map { |item| safe_tool_value(item, depth + 1, budget) }
        when Hash
          value.each_with_object({}) do |(key, item), result|
            safe_key = key.is_a?(Symbol) ? key : key.to_s
            result[safe_key] = safe_tool_value(item, depth + 1, budget)
          end
        else
          raise CodeModeExecutionError, "Tool returned unsupported #{value.class} value"
        end
      end
    end
  end
end
