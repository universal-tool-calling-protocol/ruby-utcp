# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      private

      def evaluate_keyword(keyword)
        case keyword
        when "true" then true
        when "false" then false
        when "nil" then nil
        else raise CodeModeSyntaxError, "Unsupported keyword #{keyword.inspect}"
        end
      end

      def evaluate_string_part(part)
        return part[1] if part.first == :@tstring_content
        return evaluate_statements(part[1]).to_s if part.first == :string_embexpr

        unsupported!(part)
      end

      def evaluate_symbol(node)
        token = node.first == :symbol ? node[1] : node
        token_value(token).to_sym
      end

      def evaluate_hash(contents)
        return {} unless contents
        return evaluate_associations(contents[1]) if contents.first == :assoclist_from_args

        unsupported!(contents)
      end

      def evaluate_associations(associations)
        Array(associations).each_with_object({}) do |association, result|
          unsupported!(association) unless association.first == :assoc_new
          key_node = association[1]
          key = key_node.first == :@label ? key_node[1].sub(/:\z/, "") : evaluate(key_node)
          result[key] = evaluate(association[2])
        end
      end

      def evaluate_variable_token(token)
        return evaluate_keyword(token[1]) if token.first == :@kw
        lookup(token_value(token))
      end

      def evaluate_vcall(token)
        name = token_value(token)
        value = lookup(name, missing: :sentinel)
        return value unless value == :sentinel

        call_function(name, [], nil)
      end

      def lookup(name, missing: nil)
        @scopes.reverse_each { |scope| return scope[name] if scope.key?(name) }
        return missing if missing == :sentinel

        raise CodeModeExecutionError, "Undefined local variable #{name.inspect}"
      end

      def assign(target, value)
        case target.first
        when :var_field
          name = token_value(target[1])
          scope = @scopes.reverse.find { |candidate| candidate.key?(name) } || @scopes.last
          scope[name] = value
        when :aref_field
          receiver = evaluate(target[1])
          arguments = extract_arguments(target[2])
          raise CodeModeSyntaxError, "Indexed assignment requires exactly one key" unless arguments.length == 1
          raise CodeModeSyntaxError, "Indexed assignment is only allowed on arrays and hashes" unless receiver.is_a?(Array) || receiver.is_a?(Hash)

          receiver[arguments.first] = value
        else
          unsupported!(target)
        end
        value
      end

      def evaluate_opassign(node)
        target = node[1]
        operator = token_value(node[2]).sub(/=\z/, "").to_sym
        current = read_assignment_target(target)
        assign(target, apply_binary(current, operator, evaluate(node[3])))
      end

      def read_assignment_target(target)
        case target.first
        when :var_field then lookup(token_value(target[1]))
        when :aref_field then safe_index(evaluate(target[1]), extract_arguments(target[2]))
        else unsupported!(target)
        end
      end

      def evaluate_binary(left_node, operator, right_node)
        left = evaluate(left_node)
        return left unless truthy?(left) if [:'&&', :and].include?(operator)
        return left if truthy?(left) if [:'||', :or].include?(operator)

        apply_binary(left, operator, evaluate(right_node))
      end

      def apply_binary(left, operator, right)
        preflight_binary_size!(left, operator, right)
        value = case operator
                when :+ then left + right
                when :- then left - right
                when :* then left * right
                when :/ then left / right
                when :% then left % right
                when :** then left**right
                when :== then left == right
                when :!= then left != right
                when :< then left < right
                when :<= then left <= right
                when :> then left > right
                when :>= then left >= right
                when :<=> then left <=> right
                when :'&&', :and, :'||', :or then right
                else raise CodeModeSyntaxError, "Unsupported operator #{operator.inspect}"
                end
        bounded_value!(value)
      rescue NoMethodError, TypeError, ArgumentError, ZeroDivisionError => error
        raise CodeModeExecutionError, "Invalid #{operator} operation: #{error.message}"
      end

      def evaluate_unary(operator, operand_node)
        operand = evaluate(operand_node)
        case operator
        when :! then !truthy?(operand)
        when :+@ then +operand
        when :-@ then -operand
        else raise CodeModeSyntaxError, "Unsupported unary operator #{operator.inspect}"
        end
      end

      def return_value(arguments_node)
        arguments = extract_arguments(arguments_node)
        arguments.length <= 1 ? arguments.first : arguments
      end

      def extract_arguments(node)
        return [] if node.nil?
        case node.first
        when :arg_paren then extract_arguments(node[1])
        when :args_add_block then Array(node[1]).map { |argument| evaluate(argument) }
        when :args_new then []
        when :args_add then extract_arguments(node[1]) + [evaluate(node[2])]
        else [evaluate(node)]
        end
      end

      def build_block(node)
        unsupported!(node) unless %i[brace_block do_block].include?(node.first)
        parameters = extract_block_parameters(node[1])
        Block.new(self, parameters, node[2])
      end

      def extract_block_parameters(node)
        return [] unless node
        params = node.first == :block_var ? node[1] : node
        unsupported!(params) unless params&.first == :params
        required = Array(params[1])
        unsupported!(params) unless params.drop(2).all?(&:nil?)

        required.map { |token| token_value(token) }
      end

      def evaluate_call(node, block = nil)
        case node.first
        when :method_add_arg
          invoke_call_target(node[1], extract_arguments(node[2]), block)
        when :call
          invoke_method(evaluate(node[1]), token_value(node[3]), [], block)
        when :fcall
          call_function(token_value(node[1]), [], block)
        when :vcall
          evaluate_vcall(node[1])
        when :command
          call_function(token_value(node[1]), extract_arguments(node[2]), block)
        when :command_call
          invoke_method(evaluate(node[1]), token_value(node[3]), extract_arguments(node[4]), block)
        else
          unsupported!(node)
        end
      end

      def invoke_call_target(target, arguments, block)
        case target.first
        when :call
          invoke_method(evaluate(target[1]), token_value(target[3]), arguments, block)
        when :fcall
          call_function(token_value(target[1]), arguments, block)
        when :vcall
          call_function(token_value(target[1]), arguments, block)
        else
          unsupported!(target)
        end
      end

      def call_function(name, arguments, block)
        case name
        when "puts", "print", "p", "warn"
          log(name, arguments)
          nil
        else
          hint = name == "call_tool" ? "; use codemode.call_tool(...)" : ""
          raise CodeModeSyntaxError, "Function #{name.inspect} is not available in Code Mode#{hint}"
        end
      end
    end
  end
end
