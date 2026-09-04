# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      ReturnSignal = Class.new(StandardError) do
        attr_reader :value

        def initialize(value)
          @value = value
          super()
        end
      end
      BreakSignal = Class.new(StandardError) do
        attr_reader :value

        def initialize(value = nil)
          @value = value
          super()
        end
      end
      NextSignal = Class.new(StandardError) do
        attr_reader :value

        def initialize(value = nil)
          @value = value
          super()
        end
      end

      RuntimeAPI = Class.new
      Block = Struct.new(:evaluator, :parameters, :body) do
        def call(*values)
          scope = {}
          if parameters.length == 1 && values.length > 1
            scope[parameters.first] = values
          else
            parameters.each_with_index { |name, index| scope[name] = values[index] }
          end
          evaluator.with_scope(scope) { evaluator.evaluate(body) }
        rescue NextSignal => signal
          signal.value
        end
      end

      SAFE_ENUMERABLE_METHODS = %w[
        all? any? collect count each filter find map none? reduce inject reject select sort_by
      ].freeze
      SAFE_VALUE_METHODS = %w[
        abs ceil compact dig downcase drop empty? end_with? even? fetch first flatten floor
        has_key? include? inspect join key? keys last length max merge min negative? odd? positive?
        nil? reverse round size slice sort split start_with? strip sum take to_a to_f to_h to_i to_s
        uniq upcase values zero?
      ].freeze

      attr_reader :logs

      def initialize(client, interfaces:, timeout:, max_steps:)
        raise CodeModeLimitError, "max_steps must be greater than zero" unless max_steps.positive?

        @client = client
        @interfaces = interfaces
        @deadline = monotonic_now + timeout
        @max_steps = max_steps
        @steps = 0
        @logs = []
        @log_bytes = 0
        @scopes = [{ "codemode" => RuntimeAPI.new }]
      end

      def execute(source)
        tree = Ripper.sexp(source)
        raise CodeModeSyntaxError, "Invalid Ruby syntax" unless tree

        safe_tool_value(evaluate(tree))
      rescue ReturnSignal => signal
        safe_tool_value(signal.value)
      end

      def evaluate(node)
        tick!
        return nil if node.nil?
        return node unless node.is_a?(Array)
        return evaluate_statements(node) unless node.first.is_a?(Symbol)

        type = node.first
        case type
        when :program then evaluate_statements(node[1])
        when :void_stmt then nil
        when :assign then assign(node[1], evaluate(node[2]))
        when :opassign then evaluate_opassign(node)
        when :var_ref then evaluate_variable_token(node[1])
        when :vcall then evaluate_vcall(node[1])
        when :fcall then call_function(token_value(node[1]), [], nil)
        when :@int then Integer(node[1], 10)
        when :@float then Float(node[1])
        when :@kw then evaluate_keyword(node[1])
        when :string_literal then evaluate(node[1]).to_s
        when :string_content then node.drop(1).map { |part| evaluate_string_part(part) }.join
        when :symbol_literal then evaluate_symbol(node[1])
        when :array then Array(node[1]).map { |item| evaluate(item) }
        when :hash then evaluate_hash(node[1])
        when :bare_assoc_hash then evaluate_associations(node[1])
        when :paren then evaluate_statements(node[1])
        when :binary then evaluate_binary(node[1], node[2], node[3])
        when :unary then evaluate_unary(node[1], node[2])
        when :dot2 then Range.new(evaluate(node[1]), evaluate(node[2]), false)
        when :dot3 then Range.new(evaluate(node[1]), evaluate(node[2]), true)
        when :aref then safe_index(evaluate(node[1]), extract_arguments(node[2]))
        when :call, :method_add_arg, :command, :command_call then evaluate_call(node)
        when :method_add_block then evaluate_call(node[1], build_block(node[2]))
        when :begin then evaluate(node[1])
        when :bodystmt then evaluate_body_statement(node)
        when :rescue_mod then evaluate_rescue_modifier(node)
        when :if then evaluate_if(node[1], node[2], node[3])
        when :unless then evaluate_unless(node[1], node[2], node[3])
        when :if_mod then truthy?(evaluate(node[1])) ? evaluate(node[2]) : nil
        when :unless_mod then truthy?(evaluate(node[1])) ? nil : evaluate(node[2])
        when :while then evaluate_loop(node[1], node[2], until_condition: false)
        when :until then evaluate_loop(node[1], node[2], until_condition: true)
        when :return then raise ReturnSignal, return_value(node[1])
        when :return0 then raise ReturnSignal, nil
        when :break then raise BreakSignal, return_value(node[1])
        when :next then raise NextSignal, return_value(node[1])
        else
          unsupported!(node)
        end
      end

      def evaluate_statements(statements)
        Array(statements).reduce(nil) { |_result, statement| evaluate(statement) }
      end

      def with_scope(scope)
        @scopes << scope
        yield
      ensure
        @scopes.pop
      end

      private

      def tick!
        @steps += 1
        raise CodeModeLimitError, "Code Mode step limit exceeded" if @steps > @max_steps
        raise CodeModeTimeoutError, "Code Mode execution timed out" if monotonic_now >= @deadline
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def unsupported!(node)
        line = find_line(node)
        suffix = line ? " at line #{line}" : ""
        raise CodeModeSyntaxError, "Unsupported Ruby construct #{node.first.inspect}#{suffix}"
      end

      def find_line(node)
        return node[2][0] if node.is_a?(Array) && node.first.to_s.start_with?("@") && node[2].is_a?(Array)
        return nil unless node.is_a?(Array)

        node.each do |child|
          line = find_line(child)
          return line if line
        end
        nil
      end

      def token_value(token)
        token.is_a?(Array) ? token[1].to_s : token.to_s
      end

    end
  end
end
