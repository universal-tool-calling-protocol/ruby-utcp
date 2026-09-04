# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      private

      def invoke_method(receiver, method_name, arguments, block)
        return invoke_runtime_api(method_name, arguments, block) if receiver.is_a?(RuntimeAPI)
        return receiver[method_name] if receiver.is_a?(Hash) && arguments.empty? && !block && receiver.key?(method_name)

        unless SAFE_ENUMERABLE_METHODS.include?(method_name) || SAFE_VALUE_METHODS.include?(method_name)
          raise CodeModeSyntaxError, "Method #{method_name.inspect} is not available in Code Mode"
        end

        bounded_value!(invoke_safe_value_method(receiver, method_name, arguments, block))
      end

      def invoke_safe_value_method(receiver, method_name, arguments, block)
        return invoke_enumerable(receiver, method_name, arguments, block) if SAFE_ENUMERABLE_METHODS.include?(method_name)

        case method_name
        when "length", "size" then require_arity!(method_name, arguments, 0).then { receiver.respond_to?(:length) ? receiver.length : invalid_receiver!(receiver, method_name) }
        when "empty?" then require_arity!(method_name, arguments, 0).then { receiver.respond_to?(:empty?) ? receiver.empty? : invalid_receiver!(receiver, method_name) }
        when "nil?" then require_arity!(method_name, arguments, 0).then { receiver.nil? }
        when "to_s" then require_arity!(method_name, arguments, 0).then { receiver.to_s }
        when "inspect" then require_arity!(method_name, arguments, 0).then { receiver.inspect }
        when "to_i" then require_arity!(method_name, arguments, 0).then { receiver.to_i }
        when "to_f" then require_arity!(method_name, arguments, 0).then { receiver.to_f }
        when "to_a" then require_arity!(method_name, arguments, 0).then { safe_to_a(receiver) }
        when "to_h" then require_arity!(method_name, arguments, 0).then { receiver.is_a?(Hash) ? receiver.dup : invalid_receiver!(receiver, method_name) }
        when "first" then require_arity!(method_name, arguments, 0..1).then { enumerable_value!(receiver, method_name).first(*arguments) }
        when "last" then require_arity!(method_name, arguments, 0..1).then { enumerable_value!(receiver, method_name).last(*arguments) }
        when "take" then require_arity!(method_name, arguments, 1).then { enumerable_value!(receiver, method_name).take(Integer(arguments[0])) }
        when "drop" then require_arity!(method_name, arguments, 1).then { enumerable_value!(receiver, method_name).drop(Integer(arguments[0])) }
        when "reverse", "sort", "uniq", "compact", "flatten", "keys", "values", "min", "max", "sum"
          require_arity!(method_name, arguments, 0)
          safe_zero_argument_method(receiver, method_name)
        when "join" then safe_join(require_array!(receiver, method_name), arguments)
        when "split" then bounded_value!(require_string!(receiver, method_name).split(*arguments))
        when "strip", "downcase", "upcase" then require_string!(receiver, method_name).public_send(method_name)
        when "include?" then collection_value!(receiver, method_name).include?(*arguments)
        when "start_with?", "end_with?" then require_string!(receiver, method_name).public_send(method_name, *arguments)
        when "key?", "has_key?" then require_hash!(receiver, method_name).key?(*arguments)
        when "fetch" then indexable_value!(receiver, method_name).fetch(*arguments)
        when "dig" then require_hash!(receiver, method_name).dig(*arguments)
        when "slice" then indexable_value!(receiver, method_name).slice(*arguments)
        when "merge" then bounded_value!(require_hash!(receiver, method_name).merge(require_hash!(arguments.fetch(0), method_name)))
        when "abs", "ceil", "floor", "round", "zero?", "positive?", "negative?", "even?", "odd?"
          require_numeric!(receiver, method_name).public_send(method_name, *arguments)
        else
          invalid_receiver!(receiver, method_name)
        end
      rescue NoMethodError, ArgumentError, TypeError, IndexError, KeyError => error
        raise CodeModeExecutionError, "Invalid #{method_name} call: #{error.message}"
      end

      def invoke_enumerable(receiver, method_name, arguments, block)
        enumerable = enumerable_value!(receiver, method_name)
        case method_name
        when "map", "collect" then require_block!(method_name, block).then { enumerable.map { |*items| tick!; block.call(*block_arguments(enumerable, items)) } }
        when "select", "filter" then require_block!(method_name, block).then { enumerable.select { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "reject" then require_block!(method_name, block).then { enumerable.reject { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "each"
          require_block!(method_name, block)
          enumerable.each { |*items| tick!; block.call(*block_arguments(enumerable, items)) }
          receiver
        when "find" then require_block!(method_name, block).then { enumerable.find { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "any?" then require_block!(method_name, block).then { enumerable.any? { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "all?" then require_block!(method_name, block).then { enumerable.all? { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "none?" then require_block!(method_name, block).then { enumerable.none? { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } }
        when "count"
          block ? enumerable.count { |*items| tick!; truthy?(block.call(*block_arguments(enumerable, items))) } : enumerable.count(*arguments)
        when "sort_by" then require_block!(method_name, block).then { enumerable.sort_by { |*items| tick!; block.call(*block_arguments(enumerable, items)) } }
        when "reduce", "inject"
          reduce_enumerable(enumerable, arguments, require_block!(method_name, block))
        else invalid_receiver!(receiver, method_name)
        end
      rescue BreakSignal => signal
        signal.value
      end

      def block_arguments(enumerable, items)
        return items.first if enumerable.is_a?(Hash) && items.length == 1 && items.first.is_a?(Array)

        items
      end

      def reduce_enumerable(enumerable, arguments, block)
        values = enumerable.to_a
        if arguments.empty?
          return nil if values.empty?
          accumulator = values.shift
        else
          require_arity!("reduce", arguments, 1)
          accumulator = arguments.first
        end
        values.each { |item| tick!; accumulator = block.call(accumulator, item) }
        accumulator
      end

      def safe_zero_argument_method(receiver, method_name)
        allowed = case receiver
                  when Array then %w[reverse sort uniq compact flatten min max sum]
                  when Hash then %w[keys values]
                  when Range then %w[min max sum]
                  else []
                  end
        invalid_receiver!(receiver, method_name) unless allowed.include?(method_name)
        bounded_value!(receiver.public_send(method_name))
      end

      def safe_to_a(receiver)
        return receiver.dup if receiver.is_a?(Array)
        if receiver.is_a?(Range)
          if receiver.begin.is_a?(Integer) && receiver.end.is_a?(Integer)
            size = receiver.end - receiver.begin + (receiver.exclude_end? ? 0 : 1)
            raise CodeModeLimitError, "Range contains too many values" if size > MAX_VALUE_ITEMS
          end
          return bounded_value!(receiver.to_a)
        end
        return receiver.to_a if receiver.is_a?(Hash)

        invalid_receiver!(receiver, "to_a")
      end

      def safe_index(receiver, arguments)
        raise CodeModeSyntaxError, "Indexing requires one or two arguments" unless (1..2).cover?(arguments.length)
        raise CodeModeExecutionError, "#{receiver.class} values cannot be indexed" unless receiver.is_a?(Array) || receiver.is_a?(Hash) || receiver.is_a?(String)

        receiver[*arguments]
      rescue TypeError, IndexError => error
        raise CodeModeExecutionError, "Invalid index: #{error.message}"
      end

      def enumerable_value!(receiver, method_name)
        return receiver if receiver.is_a?(Array) || receiver.is_a?(Hash) || receiver.is_a?(Range)

        invalid_receiver!(receiver, method_name)
      end

      def require_string!(value, method_name)
        return value if value.is_a?(String)

        invalid_receiver!(value, method_name)
      end

      def require_hash!(value, method_name)
        return value if value.is_a?(Hash)

        invalid_receiver!(value, method_name)
      end

      def require_array!(value, method_name)
        return value if value.is_a?(Array)

        invalid_receiver!(value, method_name)
      end

      def collection_value!(value, method_name)
        return value if value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(String) || value.is_a?(Range)

        invalid_receiver!(value, method_name)
      end

      def indexable_value!(value, method_name)
        return value if value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(String)

        invalid_receiver!(value, method_name)
      end

      def require_numeric!(value, method_name)
        return value if value.is_a?(Numeric)

        invalid_receiver!(value, method_name)
      end

      def safe_join(receiver, arguments)
        separator = arguments.empty? ? "" : arguments.first.to_s
        estimated = receiver.sum { |value| value.to_s.bytesize }
        estimated += separator.bytesize * [receiver.length - 1, 0].max
        raise CodeModeLimitError, "String result exceeds #{MAX_VALUE_BYTES} bytes" if estimated > MAX_VALUE_BYTES

        receiver.join(*arguments)
      end

      def invalid_receiver!(receiver, method_name)
        raise CodeModeExecutionError, "#{method_name} is not supported for #{receiver.class} values"
      end

      def require_block!(method_name, block)
        raise CodeModeSyntaxError, "#{method_name} requires a block" unless block
        block
      end

      def require_arity!(name, arguments, expected)
        valid = expected.is_a?(Range) ? expected.cover?(arguments.length) : arguments.length == expected
        return true if valid

        raise CodeModeSyntaxError, "#{name} received #{arguments.length} arguments"
      end
    end
  end
end
