# frozen_string_literal: true

require "logger"

module UTCP
  class Client
    attr_reader :config, :root_dir, :variable_substitutor, :logger, :registration_results

    def self.create(root_dir: nil, config: nil, logger: nil)
      client = new(root_dir: root_dir, config: config, logger: logger)
      client.register_configured_manuals
      client
    end

    def initialize(root_dir: nil, config: nil, logger: nil)
      @root_dir = File.expand_path(root_dir || Dir.pwd)
      @logger = logger || Logger.new($stderr, level: Logger::WARN)
      @config = ClientConfig.from(config, root_dir: @root_dir)
      @variable_substitutor = VariableSubstitutor.new
      @registration_results = []
    end

    def register_configured_manuals
      @registration_results = register_manuals(config.manual_call_templates)
      self
    end

    def register_manual(manual_call_template)
      template = copy_template(CallTemplate.from_h(manual_call_template))
      template.name = sanitize_name(template.name)
      if config.tool_repository.get_manual(template.name)
        raise ManualAlreadyRegisteredError,
              "Manual #{template.name.inspect} is already registered; deregister it or use another name"
      end

      template = substitute_template(template, template.name)
      protocol = fetch_protocol(template.call_template_type)
      result = protocol.register_manual(self, template)
      return result unless result.success?

      allowed = template.allowed_protocols
      filtered = result.manual.tools.each_with_object([]) do |tool, tools|
        type = tool.tool_call_template&.call_template_type || template.call_template_type
        if allowed.include?(type)
          tool.name = "#{template.name}.#{tool.name}" unless tool.name.start_with?("#{template.name}.")
          tools << tool
        else
          logger.warn(
            "Tool #{tool.name.inspect} uses protocol #{type.inspect}, which is not allowed " \
            "by manual #{template.name.inspect}; allowed protocols: #{allowed.inspect}"
          )
        end
      end
      result.manual.tools = filtered
      result.manual_call_template = template
      config.tool_repository.save_manual(template, result.manual)
      result
    end

    def register_manuals(manual_call_templates)
      Array(manual_call_templates).map do |template|
        register_manual(template)
      rescue VariableNotFoundError
        raise
      rescue StandardError => error
        parsed = CallTemplate.from_h(template)
        logger.warn("Unable to register manual #{parsed.name.inspect}: #{error.message}")
        RegisterManualResult.new(
          manual_call_template: parsed,
          manual: Manual.new(tools: [], manual_version: "0.0.0"),
          success: false,
          errors: [error.message]
        )
      end
    end

    def deregister_manual(manual_name)
      template = config.tool_repository.get_manual_call_template(manual_name)
      return false unless template

      fetch_protocol(template.call_template_type).deregister_manual(self, template)
      config.tool_repository.remove_manual(manual_name)
    end

    def call_tool(tool_name, tool_args = {})
      tool = config.tool_repository.get_tool(tool_name)
      raise ToolNotFoundError, "Tool not found: #{tool_name}" unless tool

      manual_name = tool_name.to_s.split(".", 2).first
      template = substitute_template(tool.tool_call_template, manual_name)
      enforce_allowed_protocol!(manual_name, tool_name, template.call_template_type)
      result = fetch_protocol(template.call_template_type).call_tool(self, tool_name, tool_args, template)
      apply_post_processing(result, tool, template)
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("Tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    def call_tool_streaming(tool_name, tool_args = {})
      return enum_for(__method__, tool_name, tool_args) unless block_given?

      tool = config.tool_repository.get_tool(tool_name)
      raise ToolNotFoundError, "Tool not found: #{tool_name}" unless tool

      manual_name = tool_name.to_s.split(".", 2).first
      template = substitute_template(tool.tool_call_template, manual_name)
      enforce_allowed_protocol!(manual_name, tool_name, template.call_template_type)
      protocol = fetch_protocol(template.call_template_type)
      protocol.call_tool_streaming(self, tool_name, tool_args, template) do |item|
        yield apply_post_processing(item, tool, template)
      end
    end

    def search_tools(query, limit: 10, any_of_tags_required: nil)
      config.tool_search_strategy.search_tools(
        tool_repository: config.tool_repository,
        query: query,
        limit: limit,
        any_of_tags_required: any_of_tags_required
      )
    end

    def list_tools
      config.tool_repository.get_tools
    end

    def get_required_variables_for_manual_and_tools(manual_call_template)
      template = copy_template(CallTemplate.from_h(manual_call_template))
      template.name = sanitize_name(template.name)
      required = variable_substitutor.find_required_variables(template.to_h, template.name)
      return required unless required.empty?

      substituted = substitute_template(template, template.name)
      protocol = fetch_protocol(substituted.call_template_type)
      # Give discovery its own session owner and repository, even for an existing manual.
      inspection_config = config.dup
      inspection_config.tool_repository = InMemoryToolRepository.new
      inspection_config.manual_call_templates = []
      inspection_client = Client.new(root_dir: root_dir, config: inspection_config, logger: logger)
      begin
        result = protocol.register_manual(inspection_client, substituted)
        return [] unless result.success?

        result.manual.tools.flat_map do |tool|
          variable_substitutor.find_required_variables(tool.tool_call_template.to_h, template.name)
        end.uniq
      ensure
        protocol.deregister_manual(inspection_client, substituted)
      end
    end

    def get_required_variables_for_registered_tool(tool_name)
      tool = config.tool_repository.get_tool(tool_name)
      raise ToolNotFoundError, "Tool not found: #{tool_name}" unless tool

      manual_name = tool_name.to_s.split(".", 2).first
      variable_substitutor.find_required_variables(tool.tool_call_template.to_h, manual_name)
    end

    def manual(name)
      config.tool_repository.get_manual(name)
    end

    def manuals
      config.tool_repository.get_manuals
    end

    def close
      config.tool_repository.get_manual_call_templates.each do |template|
        deregister_manual(template.name)
      rescue StandardError => error
        logger.warn("Unable to deregister manual #{template.name.inspect}: #{error.message}")
      end
      nil
    end

    private

    def fetch_protocol(type)
      UTCP.protocol(type) || raise(
        ProtocolNotFoundError,
        "No communication protocol registered for #{type.inspect}; available: #{UTCP.protocol_types.join(', ')}"
      )
    end

    def sanitize_name(name)
      sanitized = name.to_s.gsub(/[^[:alnum:]_]/, "_")
      raise ValidationError, "manual name cannot be empty" if sanitized.empty?

      sanitized
    end

    def substitute_template(template, namespace)
      substituted = variable_substitutor.substitute(template.to_h, config, namespace)
      CallTemplate.from_h(substituted)
    end

    def copy_template(template)
      CallTemplate.from_h(template.to_h)
    end

    def enforce_allowed_protocol!(manual_name, tool_name, type)
      manual_template = config.tool_repository.get_manual_call_template(manual_name)
      return unless manual_template
      return if manual_template.allowed_protocols.include?(type)

      raise ProtocolNotAllowedError,
            "Tool #{tool_name.inspect} uses protocol #{type.inspect}, which is not allowed by " \
            "manual #{manual_name.inspect}; allowed protocols: #{manual_template.allowed_protocols.inspect}"
    end

    def apply_post_processing(result, tool, template)
      config.post_processing.reduce(result) do |value, processor|
        if processor.respond_to?(:post_process)
          processor.post_process(self, tool, template, value)
        elsif processor.respond_to?(:call)
          processor.call(value)
        else
          raise ValidationError, "post processor must respond to call or post_process"
        end
      end
    end
  end
  UtcpClient = Client
end
