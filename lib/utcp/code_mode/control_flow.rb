# frozen_string_literal: true

module UTCP
  class CodeMode
    class Evaluator
      private

      def truthy?(value)
        !value.nil? && value != false
      end

      def evaluate_if(condition, truthy_statements, alternative)
        if truthy?(evaluate(condition))
          evaluate_statements(truthy_statements)
        elsif alternative&.first == :else
          evaluate_statements(alternative[1])
        elsif alternative&.first == :elsif
          evaluate_if(alternative[1], alternative[2], alternative[3])
        end
      end

      def evaluate_unless(condition, statements, alternative)
        unless truthy?(evaluate(condition))
          evaluate_statements(statements)
        else
          evaluate_statements(alternative[1]) if alternative&.first == :else
        end
      end

      def evaluate_body_statement(node)
        statements, rescue_clause, else_clause, ensure_clause = node.drop(1)
        completed = false
        result = begin
          value = evaluate_statements(statements)
          completed = true
          value
        rescue ReturnSignal, BreakSignal, NextSignal, CodeModeTimeoutError, CodeModeLimitError, CodeModeSyntaxError
          raise
        rescue StandardError => error
          raise unless rescue_clause
          evaluate_rescue_clause(rescue_clause, error)
        ensure
          evaluate_statements(ensure_clause[1]) if ensure_clause&.first == :ensure
        end
        completed && else_clause ? evaluate_statements(else_clause) : result
      end

      def evaluate_rescue_clause(node, error)
        unsupported!(node) unless node.first == :rescue
        raise CodeModeSyntaxError, "Code Mode rescue does not accept exception classes" if node[1]

        scope = {}
        assign_rescue_variable(scope, node[2], error) if node[2]
        with_scope(scope) { evaluate_statements(node[3]) }
      rescue ReturnSignal, BreakSignal, NextSignal, CodeModeTimeoutError, CodeModeLimitError, CodeModeSyntaxError
        raise
      rescue StandardError => nested
        next_clause = node[4]
        raise nested unless next_clause&.first == :rescue
        evaluate_rescue_clause(next_clause, nested)
      end

      def assign_rescue_variable(scope, target, error)
        unsupported!(target) unless target.first == :var_field
        scope[token_value(target[1])] = {
          "message" => error.message,
          "type" => error.class.name
        }
      end

      def evaluate_rescue_modifier(node)
        evaluate(node[1])
      rescue ReturnSignal, BreakSignal, NextSignal, CodeModeTimeoutError, CodeModeLimitError, CodeModeSyntaxError
        raise
      rescue StandardError
        evaluate(node[2])
      end

      def evaluate_loop(condition, statements, until_condition:)
        result = nil
        loop do
          matches = truthy?(evaluate(condition))
          break if until_condition ? matches : !matches

          begin
            result = evaluate_statements(statements)
          rescue NextSignal => signal
            result = signal.value
          rescue BreakSignal => signal
            return signal.value
          end
        end
        result
      end
    end
  end
end
