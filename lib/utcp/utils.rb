# frozen_string_literal: true

require "json"
require "yaml"

module UTCP
  module ModelSerialization
    def to_json(*arguments)
      to_h.to_json(*arguments)
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end
  end

  module Utils
    module_function

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), copy| copy[key.to_s] = stringify_keys(item) }
      when Array
        value.map { |item| stringify_keys(item) }
      else
        value
      end
    end

    def symbolize_keys(value)
      value.each_with_object({}) { |(key, item), copy| copy[key.to_sym] = item }
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
      when Array
        value.map { |item| deep_copy(item) }
      when String
        value.dup
      else
        value
      end
    end

    def compact_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[key] = value unless value.nil?
      end
    end

    def required_string!(value, field)
      return value if value.is_a?(String) && !value.empty?

      raise ValidationError.new("must be a non-empty String", path: field)
    end

    def optional_string!(value, field)
      return nil if value.nil?
      return value if value.is_a?(String)

      raise ValidationError.new("must be a String", path: field)
    end

    def hash!(value, field)
      return value if value.is_a?(Hash)

      raise ValidationError.new("must be an object", path: field)
    end

    def array!(value, field)
      return value if value.is_a?(Array)

      raise ValidationError.new("must be an array", path: field)
    end

    def parse_document(content, source: nil)
      JSON.parse(content)
    rescue JSON::ParserError => json_error
      begin
        parsed = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: false)
        raise ValidationError, "document is empty" if parsed.nil?

        parsed
      rescue Psych::Exception, ValidationError => yaml_error
        label = source ? " #{source}" : ""
        raise SerializerValidationError,
              "Could not parse#{label} as JSON or safe YAML: #{json_error.message}; #{yaml_error.message}"
      end
    end

    def load_document(path)
      parse_document(File.read(path, mode: "r:bom|utf-8"), source: path)
    rescue Errno::ENOENT => error
      raise ValidationError, "File not found: #{path} (#{error.message})"
    rescue Errno::EACCES => error
      raise ValidationError, "Cannot read file: #{path} (#{error.message})"
    end

    def json_value(value)
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass
        value
      when Hash, Array
        value
      else
        value.to_s
      end
    end
  end
end
