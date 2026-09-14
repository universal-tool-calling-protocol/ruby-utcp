# frozen_string_literal: true

require "ripper"

module CodingAgent
  # A lexical declaration index, not runtime constant or method resolution.
  # Parsing never loads or executes the workspace's Ruby files.
  module RubySymbols
    class ParseError < StandardError; end

    def self.each(source)
      begin
        tree = Ripper.sexp(source)
      rescue ArgumentError, SystemStackError => error
        raise ParseError, error.message
      end
      raise ParseError, "Invalid Ruby source" unless tree

      # Use an explicit stack so traversal does not add Ruby call-stack depth.
      pending = [[tree, "", nil]]
      until pending.empty?
        node, scope, singleton = pending.pop
        next unless node.is_a?(Array)

        case node[0]
        when :class, :module
          name, token = constant(node[1])
          next unless name

          qualified = qualify(scope, name)
          yield entry(token, qualified, node[0].to_s)
          body = node[node[0] == :class ? 3 : 2]
          pending << [body, qualified, nil]
          next
        when :sclass
          owner = receiver(node[1], scope, singleton)
          pending << [node[2], scope, owner]
          next
        when :def
          owner = singleton || (scope.empty? ? "Object" : scope)
          separator = singleton ? "." : "#"
          yield entry(node[1], owner + separator + node[1][1], singleton ? "singleton_method" : "method")
        when :defs
          owner = receiver(node[1], scope, singleton)
          yield entry(node[3], owner + "." + node[3][1], "singleton_method")
        when :var_field, :const_path_field, :top_const_field
          name, token = constant(node)
          yield entry(token, qualify(scope, name), "constant") if name
        end

        node.reverse_each { |child| pending << [child, scope, singleton] if child.is_a?(Array) }
      end
    end

    def self.entry(token, qualified, kind)
      { "name" => token[1], "qualified_name" => qualified, "kind" => kind, "line" => token[2][0] }
    end

    def self.qualify(scope, name)
      return name.delete_prefix("::") if name.start_with?("::")

      scope.empty? ? name : scope + "::" + name
    end

    def self.receiver(node, scope, singleton)
      if node[0] == :var_ref && node[1][0] == :@kw && node[1][1] == "self"
        return singleton + ".singleton_class" if singleton

        return scope.empty? ? "self" : scope
      end
      name, = constant(node)
      return qualify(scope, name) if name

      # A local or computed receiver cannot be resolved without executing code.
      "<receiver>"
    end

    def self.constant(node)
      parts = []
      token = nil
      while node.is_a?(Array)
        case node[0]
        when :@const
          token ||= node
          parts.unshift(node[1])
          return [parts.join("::"), token]
        when :const_ref, :var_ref, :var_field
          node = node[1]
        when :const_path_ref, :const_path_field
          token ||= node[2]
          parts.unshift(node[2][1])
          node = node[1]
        when :top_const_ref, :top_const_field
          token ||= node[1]
          parts.unshift(node[1][1])
          return ["::" + parts.join("::"), token]
        else
          break
        end
      end
      nil
    end

    private_class_method :entry, :qualify, :receiver, :constant
  end
end
