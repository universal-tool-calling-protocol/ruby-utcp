# frozen_string_literal: true

module UTCP
  class CodeMode
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
  end
end
