# frozen_string_literal: true

module UTCP
  class InMemoryToolRepository
    attr_reader :tool_repository_type

    def initialize
      @tool_repository_type = "in_memory"
      @tools = {}
      @manuals = {}
      @templates = {}
      @mutex = Mutex.new
    end

    def save_manual(manual_call_template, manual)
      @mutex.synchronize do
        old_manual = @manuals[manual_call_template.name]
        old_manual&.tools&.each { |tool| @tools.delete(tool.name) }

        @templates[manual_call_template.name] = manual_call_template
        @manuals[manual_call_template.name] = manual
        manual.tools.each { |tool| @tools[tool.name] = tool }
      end
      nil
    end

    def remove_manual(manual_name)
      @mutex.synchronize do
        manual = @manuals.delete(manual_name.to_s)
        return false unless manual

        manual.tools.each { |tool| @tools.delete(tool.name) }
        @templates.delete(manual_name.to_s)
        true
      end
    end

    def remove_tool(tool_name)
      @mutex.synchronize do
        tool = @tools.delete(tool_name.to_s)
        return false unless tool

        @manuals.each_value { |manual| manual.tools.delete_if { |candidate| candidate.name == tool.name } }
        true
      end
    end

    def get_tool(tool_name)
      @mutex.synchronize { @tools[tool_name.to_s] }
    end

    def get_tools
      @mutex.synchronize { @tools.values.dup }
    end

    def get_tools_by_manual(manual_name)
      @mutex.synchronize do
        manual = @manuals[manual_name.to_s]
        manual&.tools&.dup
      end
    end

    def get_manual(manual_name)
      @mutex.synchronize { @manuals[manual_name.to_s] }
    end

    def get_manuals
      @mutex.synchronize { @manuals.values.dup }
    end

    def get_manual_call_template(manual_name)
      @mutex.synchronize { @templates[manual_name.to_s] }
    end

    def get_manual_call_templates
      @mutex.synchronize { @templates.values.dup }
    end

    def to_h
      { "tool_repository_type" => tool_repository_type }
    end
  end
  InMemToolRepository = InMemoryToolRepository

  class TagSearchStrategy
    attr_reader :tool_search_strategy_type, :description_weight, :tag_weight

    def initialize(description_weight: 1, tag_weight: 3)
      @tool_search_strategy_type = "tag_and_description_word_match"
      @description_weight = Float(description_weight)
      @tag_weight = Float(tag_weight)
    end

    def search_tools(tool_repository:, query:, limit: 10, any_of_tags_required: nil)
      raise ArgumentError, "limit must be non-negative" if limit.negative?

      query_text = query.to_s.downcase
      query_words = query_text.scan(/[[:alnum:]_]+/).uniq
      required_tags = Array(any_of_tags_required).map { |tag| tag.to_s.downcase }
      tools = tool_repository.get_tools
      unless required_tags.empty?
        tools = tools.select do |tool|
          (tool.tags.map(&:downcase) & required_tags).any?
        end
      end

      scored = tools.each_with_index.map do |tool, index|
        score = tool.tags.sum do |tag|
          normalized = tag.downcase
          if query_text.include?(normalized) || (normalized.scan(/[[:alnum:]_]+/) & query_words).any?
            tag_weight
          else
            0
          end
        end
        description_words = tool.description.downcase.scan(/[[:alnum:]_]+/).uniq
        score += (description_words & query_words).count { |word| word.length > 2 } * description_weight
        name_words = tool.name.downcase.scan(/[[:alnum:]_]+/).uniq
        score += (name_words & query_words).length * description_weight
        [tool, score, index]
      end

      results = scored.sort_by { |_tool, score, index| [-score, index] }.map(&:first)
      limit.zero? ? results : results.first(limit)
    end

    def to_h
      {
        "tool_search_strategy_type" => tool_search_strategy_type,
        "description_weight" => description_weight,
        "tag_weight" => tag_weight
      }
    end
  end
  TagAndDescriptionWordMatchStrategy = TagSearchStrategy
end

