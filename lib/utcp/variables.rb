# frozen_string_literal: true

module UTCP
  class VariableLoader
    attr_reader :variable_loader_type

    def self.from_h(value, root_dir: Dir.pwd)
      return value if value.respond_to?(:get)

      data = Utils.stringify_keys(Utils.hash!(value, "variable loader"))
      case data["variable_loader_type"]
      when "dotenv"
        DotenvVariableLoader.new(
          env_file_path: data["env_file_path"] || ".env",
          root_dir: root_dir
        )
      else
        raise ValidationError.new(
          "unsupported variable loader type #{data['variable_loader_type'].inspect}",
          path: "variable_loader_type"
        )
      end
    end

    def initialize(variable_loader_type)
      @variable_loader_type = variable_loader_type
    end

    def get(_key)
      raise NotImplementedError
    end
  end

  class DotenvVariableLoader < VariableLoader
    attr_reader :env_file_path

    def initialize(env_file_path: ".env", root_dir: Dir.pwd)
      super("dotenv")
      @env_file_path = File.expand_path(env_file_path, root_dir)
      @variables = nil
      @mutex = Mutex.new
    end

    def get(key)
      load_variables.fetch(key.to_s, nil)
    end

    def reload!
      @mutex.synchronize { @variables = nil }
      self
    end

    def to_h
      { "variable_loader_type" => variable_loader_type, "env_file_path" => env_file_path }
    end

    private

    def load_variables
      @mutex.synchronize do
        @variables ||= parse_file
      end
    end

    def parse_file
      return {} unless File.file?(env_file_path)

      File.readlines(env_file_path, chomp: true).each_with_object({}) do |line, values|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        stripped = stripped.sub(/\Aexport\s+/, "")
        key, raw = stripped.split("=", 2)
        next unless raw && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        values[key] = parse_value(raw.strip)
      end
    end

    def parse_value(raw)
      if raw.length >= 2 && raw.start_with?("'") && raw.end_with?("'")
        raw[1..-2]
      elsif raw.length >= 2 && raw.start_with?("\"") && raw.end_with?("\"")
        raw[1..-2].gsub(/\\n/, "\n").gsub(/\\r/, "\r").gsub(/\\t/, "\t").gsub(/\\\"/, "\"")
      else
        raw.sub(/\s+#.*\z/, "")
      end
    end
  end

  class VariableSubstitutor
    VARIABLE_PATTERN = /\$\{([A-Za-z0-9_]+)\}|\$([A-Za-z0-9_]+)/.freeze
    JSON_REF_PATTERN = /\$ref(?![A-Za-z0-9_])/.freeze

    def substitute(value, config, namespace = nil)
      validate_namespace!(namespace)
      case value
      when String
        return value if value.match?(JSON_REF_PATTERN)

        value.gsub(VARIABLE_PATTERN) do
          key = Regexp.last_match(1) || Regexp.last_match(2)
          next Regexp.last_match(0) if key.match?(/\ACMD_\d+_OUTPUT\z/)

          resolve(key, config, namespace)
        end
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = substitute(item, config, namespace)
        end
      when Array
        value.map { |item| substitute(item, config, namespace) }
      else
        value
      end
    end

    def find_required_variables(value, namespace = nil)
      validate_namespace!(namespace)
      names = collect_required_variables(value)
      names.map { |name| namespace ? "#{encoded_namespace(namespace)}_#{name}" : name }.uniq
    end

    private

    def resolve(key, config, namespace)
      candidates = namespace ? ["#{encoded_namespace(namespace)}_#{key}", key] : [key]
      candidates.each do |candidate|
        direct = config.variables[candidate]
        return direct.to_s unless direct.nil?

        config.load_variables_from.each do |loader|
          loaded = loader.get(candidate)
          return loaded.to_s unless loaded.nil?
        end

        environment = ENV[candidate]
        return environment unless environment.nil?
      end

      raise VariableNotFoundError, candidates.first
    end

    def collect_required_variables(value)
      case value
      when String
        return [] if value.match?(JSON_REF_PATTERN)

        value.scan(VARIABLE_PATTERN).map { |groups| groups.compact.first }
             .reject { |name| name.match?(/\ACMD_\d+_OUTPUT\z/) }
      when Hash
        value.values.flat_map { |item| collect_required_variables(item) }
      when Array
        value.flat_map { |item| collect_required_variables(item) }
      else
        []
      end
    end

    def encoded_namespace(namespace)
      namespace.to_s.gsub("_", "__")
    end

    def validate_namespace!(namespace)
      return if namespace.nil? || namespace.to_s.match?(/\A[[:alnum:]_]+\z/)

      raise ArgumentError, "variable namespace may only contain letters, numbers, and underscores"
    end
  end
end
