# frozen_string_literal: true

require "json"
require "ripper"
require "timeout"

module UTCP
  # Executes a deliberately small, non-eval Ruby subset for composing UTCP tools.
  # The interpreter only exposes JSON-like values and explicit tool helpers.
  class CodeMode
    DEFAULT_TIMEOUT = 30
    DEFAULT_MAX_STEPS = 100_000
    MAX_CODE_BYTES = 64 * 1024
    MAX_LOG_BYTES = 1024 * 1024
    MAX_VALUE_BYTES = 1024 * 1024
    MAX_VALUE_ITEMS = 10_000
    MAX_INTEGER_BITS = MAX_VALUE_BYTES * 8

    attr_reader :client

    def initialize(client)
      @client = client
    end

    def execute(code, timeout: DEFAULT_TIMEOUT, max_steps: DEFAULT_MAX_STEPS)
      source = String(code)
      raise CodeModeLimitError, "Code exceeds #{MAX_CODE_BYTES} bytes" if source.bytesize > MAX_CODE_BYTES

      seconds = Float(timeout)
      raise CodeModeLimitError, "timeout must be greater than zero" unless seconds.positive?

      evaluator = Evaluator.new(
        client,
        interfaces: interfaces,
        timeout: seconds,
        max_steps: Integer(max_steps)
      )
      result = Timeout.timeout(seconds, CodeModeTimeoutError) { evaluator.execute(source) }
      { "result" => result, "logs" => evaluator.logs.dup }
    rescue CodeModeTimeoutError
      raise CodeModeTimeoutError, "Code Mode execution exceeded #{timeout} seconds"
    rescue CodeModeExecutionError => error
      logs = defined?(evaluator) && evaluator ? evaluator.logs : error.logs
      raise CodeModeExecutionError.new(error.message, logs: logs)
    rescue CodeModeError
      raise
    rescue StandardError => error
      logs = defined?(evaluator) && evaluator ? evaluator.logs : []
      raise CodeModeExecutionError.new("Code Mode execution failed: #{error.message}", logs: logs)
    end

    def interfaces
      InterfaceGenerator.new(client.list_tools).render
    end

    def tool_interface(name)
      tool = client.list_tools.find { |candidate| candidate.name == name.to_s }
      raise ToolNotFoundError, "Tool not found: #{name}" unless tool

      InterfaceGenerator.tool_descriptor(tool)
    end

    class InterfaceGenerator
      RUBY_KEYWORDS = %w[
        BEGIN END alias and begin break case class def defined? do else elsif end ensure false
        for if in module next nil not or redo rescue retry return self super then true undef
        unless until when while yield
      ].freeze

      class << self
        def tool_descriptor(tool)
          {
            "name" => tool.name,
            "description" => tool.description,
            "inputs" => tool.inputs.to_h,
            "outputs" => tool.outputs.to_h,
            "tags" => tool.tags.dup
          }
        end

        def identifier(value)
          name = value.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
          name = "_#{name}" if name.match?(/\A\d/)
          name = "_#{name}" if RUBY_KEYWORDS.include?(name)
          name.empty? ? "_" : name
        end

        def ruby_type(schema)
          value = schema.is_a?(Hash) ? schema : {}
          case value["type"] || value[:type]
          when "string" then "String"
          when "integer" then "Integer"
          when "number" then "Numeric"
          when "boolean" then "Boolean"
          when "array" then "Array"
          when "object" then "Hash"
          when Array then (value["type"] || value[:type]).map { |type| ruby_type("type" => type) }.join(" | ")
          else "Object"
          end
        end
      end

      def initialize(tools)
        @tools = tools.sort_by(&:name)
      end

      def render
        return "# No UTCP tools are registered." if @tools.empty?

        @tools.map { |tool| render_tool(tool) }.join("\n\n")
      end

      private

      def render_tool(tool)
        descriptor = self.class.tool_descriptor(tool)
        schema = descriptor["inputs"]
        properties = schema.fetch("properties", {})
        required = Array(schema["required"])
        parameters = properties.map do |name, property|
          suffix = required.include?(name.to_s) ? ":" : ": nil"
          "#{self.class.identifier(name)}#{suffix}"
        end
        signature = parameters.empty? ? "" : parameters.join(", ")
        description = descriptor["description"].to_s.strip
        lines = []
        lines << "# #{description}" unless description.empty?
        unless properties.empty?
          parameter_docs = properties.map do |name, property|
            requirement = required.include?(name.to_s) ? "required" : "optional"
            "#{self.class.identifier(name)} (#{self.class.ruby_type(property)}, #{requirement})"
          end
          lines << "# Parameters: #{parameter_docs.join(', ')}"
        end
        lines << "# Returns: #{self.class.ruby_type(descriptor["outputs"])}"
        separator = signature.empty? ? "" : ", "
        lines << "codemode.call_tool(#{descriptor["name"].inspect}#{separator}#{signature})"
        lines.join("\n")
      end
    end

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
          evaluator.with_scope(scope) { evaluator.evaluate_statements(body) }
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

      def invoke_method(receiver, method_name, arguments, block)
        return invoke_runtime_api(method_name, arguments, block) if receiver.is_a?(RuntimeAPI)
        return receiver[method_name] if receiver.is_a?(Hash) && arguments.empty? && !block && receiver.key?(method_name)

        unless SAFE_ENUMERABLE_METHODS.include?(method_name) || SAFE_VALUE_METHODS.include?(method_name)
          raise CodeModeSyntaxError, "Method #{method_name.inspect} is not available in Code Mode"
        end

        bounded_value!(invoke_safe_value_method(receiver, method_name, arguments, block))
      end

      def invoke_runtime_api(method_name, arguments, block)
        raise CodeModeSyntaxError, "codemode.#{method_name} does not accept a block" if block

        case method_name
        when "call_tool"
          require_arity!("codemode.call_tool", arguments, 1..2)
          safe_tool_value(@client.call_tool(arguments[0], tool_arguments(arguments[1])))
        when "call_tool_stream", "call_tool_streaming"
          require_arity!("codemode.#{method_name}", arguments, 1..2)
          safe_tool_value(@client.call_tool_streaming(arguments[0], tool_arguments(arguments[1])).to_a)
        when "search_tools"
          require_arity!("codemode.search_tools", arguments, 1..2)
          options = arguments[1].is_a?(Hash) ? arguments[1] : {}
          limit = arguments[1].is_a?(Numeric) ? arguments[1] : options.fetch("limit", 10)
          safe_tool_value(@client.search_tools(arguments[0].to_s, limit: Integer(limit)).map do |tool|
            InterfaceGenerator.tool_descriptor(tool)
          end)
        when "get_tool_interface"
          require_arity!("codemode.get_tool_interface", arguments, 1)
          tool = @client.list_tools.find { |candidate| candidate.name == arguments.first.to_s }
          raise ToolNotFoundError, "Tool not found: #{arguments.first}" unless tool
          safe_tool_value(InterfaceGenerator.tool_descriptor(tool))
        when "interfaces"
          require_arity!("codemode.interfaces", arguments, 0)
          @interfaces.dup
        when "get"
          runtime_get(arguments)
        else
          raise CodeModeSyntaxError, "Method #{method_name.inspect} is not available on codemode"
        end
      end

      def runtime_get(arguments)
        require_arity!("codemode.get", arguments, 2..3)
        receiver, key, default = arguments
        return receiver.fetch(key, default) if receiver.is_a?(Hash)
        return receiver.fetch(Integer(key), default) if receiver.is_a?(Array)
        return receiver[key] || default if receiver.is_a?(String)

        raise CodeModeExecutionError, "codemode.get requires a hash, array, or string"
      rescue IndexError, TypeError
        default
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

      def tool_arguments(value)
        return {} if value.nil?
        raise CodeModeSyntaxError, "Tool arguments must be a hash" unless value.is_a?(Hash)

        safe_tool_value(value)
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

      def log(kind, values)
        rendered = values.map { |value| kind == "p" ? value.inspect : value.to_s }.join(kind == "print" ? "" : " ")
        rendered = "[WARN] #{rendered}" if kind == "warn"
        bytes = rendered.bytesize
        raise CodeModeLimitError, "Code Mode log limit exceeded" if @log_bytes + bytes > MAX_LOG_BYTES

        @logs << rendered
        @log_bytes += bytes
      end

    end
  end

  class CodeModeUtcpClient < Client
    AGENT_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Use `codemode.search_tools` before writing a Code Mode program when tool names are unknown.
      Call tools as `codemode.call_tool("manual.tool", key: value)`. Use the exact qualified name.
      Code Mode accepts a constrained Ruby subset: local variables, JSON-like literals, arithmetic,
      conditionals, bounded loops, and common Array/Hash/String transforms. The final expression or an
      explicit `return` is the result. Use `puts`, `print`, `p`, or `warn` for captured logs. The values
      `codemode.interfaces` and `codemode.get_tool_interface("manual.tool")` describe registered tools. Filesystem,
      process, constants, imports, reflection, eval, and direct network access are unavailable.
    PROMPT

    def call_tool_chain(code, timeout_value = nil, timeout: nil, max_steps: CodeMode::DEFAULT_MAX_STEPS)
      selected_timeout = timeout || timeout_value || CodeMode::DEFAULT_TIMEOUT
      CodeMode.new(self).execute(code, timeout: selected_timeout, max_steps: max_steps)
    end

    def get_all_tools_ruby_interfaces
      CodeMode.new(self).interfaces
    end

    def get_tool_interface(name)
      CodeMode.new(self).tool_interface(name)
    end
  end

  CodeModeClient = CodeModeUtcpClient
end
