# frozen_string_literal: true

module UTCP
  class ClientConfig
    include ModelSerialization
    attr_accessor :variables, :load_variables_from, :tool_repository,
                  :tool_search_strategy, :post_processing, :manual_call_templates

    def self.from(value = nil, root_dir: Dir.pwd)
      return new(root_dir: root_dir) if value.nil?
      return value if value.is_a?(self)

      data = if value.respond_to?(:to_path) || value.is_a?(String)
               Utils.load_document(File.expand_path(value.to_s, root_dir))
             else
               value
             end
      new(root_dir: root_dir, **Utils.symbolize_keys(Utils.stringify_keys(Utils.hash!(data, "client config"))))
    end

    def self.from_h(value, root_dir: Dir.pwd)
      from(value, root_dir: root_dir)
    end

    def initialize(variables: nil, load_variables_from: nil, tool_repository: nil,
                   tool_search_strategy: nil, post_processing: nil,
                   manual_call_templates: nil, root_dir: Dir.pwd, **_extra)
      @variables = Utils.stringify_keys(variables || {})
      @load_variables_from = Array(load_variables_from).map do |loader|
        VariableLoader.from_h(loader, root_dir: root_dir)
      end
      @tool_repository = build_repository(tool_repository)
      @tool_search_strategy = build_search_strategy(tool_search_strategy)
      @post_processing = Array(post_processing)
      @manual_call_templates = Array(manual_call_templates).map { |template| CallTemplate.from_h(template) }
    end

    def to_h
      {
        "variables" => Utils.deep_copy(variables),
        "load_variables_from" => load_variables_from.map { |loader| loader.respond_to?(:to_h) ? loader.to_h : loader },
        "tool_repository" => tool_repository.respond_to?(:to_h) ? tool_repository.to_h : tool_repository,
        "tool_search_strategy" => tool_search_strategy.respond_to?(:to_h) ? tool_search_strategy.to_h : tool_search_strategy,
        "post_processing" => post_processing.map { |processor| processor.respond_to?(:to_h) ? processor.to_h : processor },
        "manual_call_templates" => manual_call_templates.map(&:to_h)
      }
    end

    private

    def build_repository(value)
      return value if value && value.respond_to?(:save_manual)

      data = Utils.stringify_keys(value || { "tool_repository_type" => "in_memory" })
      case data["tool_repository_type"]
      when nil, "in_memory"
        InMemoryToolRepository.new
      else
        raise ValidationError, "Unsupported tool_repository_type: #{data['tool_repository_type']}"
      end
    end

    def build_search_strategy(value)
      return value if value && value.respond_to?(:search_tools)

      data = Utils.stringify_keys(value || { "tool_search_strategy_type" => "tag_and_description_word_match" })
      case data["tool_search_strategy_type"]
      when nil, "tag_and_description_word_match"
        TagSearchStrategy.new(
          description_weight: data.fetch("description_weight", 1),
          tag_weight: data.fetch("tag_weight", 3)
        )
      else
        raise ValidationError, "Unsupported tool_search_strategy_type: #{data['tool_search_strategy_type']}"
      end
    end
  end
  UtcpClientConfig = ClientConfig
end
