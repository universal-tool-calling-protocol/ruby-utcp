# frozen_string_literal: true

require "utcp"
require_relative "workspace"

module RubyUTCPAgent
  # An example-local, in-process protocol. It does not override any SDK transport.
  # Discovery, schemas, namespacing and invocation still go through the real SDK.
  class WorkspaceProtocol < UTCP::CommunicationProtocol
    TYPE = "coding_agent_local"

    def register_manual(_client, template)
      tools = definitions.map do |name, description, properties, required|
        { "name" => name, "description" => description,
          "inputs" => { "type" => "object", "properties" => properties,
                        "required" => required, "additionalProperties" => false },
          "outputs" => { "type" => "object" },
          "tool_call_template" => { "name" => name, "call_template_type" => TYPE } }
      end
      success(template, manual_from_payload(template, { "tools" => tools }))
    end

    def call_tool(client, tool_name, arguments, _template)
      client.workspace.call(tool_name.split(".", 2).last, arguments)
    end

    private

    def definitions
      path = { "type" => "string", "description" => "Workspace-relative path; no symlinks or protected secrets." }
      text = { "type" => "string" }
      revision = { "type" => "string", "description" => "The full-file sha256 from read_file. Required for existing files." }
      [
        ["list_files", "List files, skipping common generated folders and protected secrets.", { "path" => path }, []],
        ["read_file", "Read UTF-8 text and its full-file sha256. Use ranges when truncated.",
         { "path" => path, "start_line" => { "type" => "integer", "minimum" => 1 },
           "max_lines" => { "type" => "integer", "minimum" => 1, "maximum" => 1000 } }, ["path"]],
        ["search", "Find literal text in workspace files; results include line numbers.",
         { "query" => text, "path" => path }, ["query"]],
        ["write_file", "Create or replace a complete UTF-8 file after approval. Omit expected_sha256 only for new files.",
         { "path" => path, "content" => text, "expected_sha256" => revision }, %w[path content]],
        ["replace_text", "Replace exactly one unique literal block after approval and revision validation.",
         { "path" => path, "old_text" => text, "new_text" => text, "expected_sha256" => revision },
         %w[path old_text new_text expected_sha256]],
        ["run_command", "Run an argv array in the workspace after approval. Return combined output, exit status and timeout state.",
         { "argv" => { "type" => "array", "items" => text, "minItems" => 1, "maxItems" => 128 },
           "timeout_seconds" => { "type" => "integer", "minimum" => 1, "maximum" => 120 } }, ["argv"]]
      ]
    end
  end

  class WorkspaceClient < UTCP::Client
    attr_reader :workspace

    def self.build(workspace)
      UTCP.register_call_template(WorkspaceProtocol::TYPE, UTCP::CallTemplate)
      UTCP.register_protocol(WorkspaceProtocol::TYPE, WorkspaceProtocol.new)
      client = new(workspace)
      result = client.register_manual(name: "workspace", call_template_type: WorkspaceProtocol::TYPE)
      raise UTCP::Error, "workspace registration failed: #{result.errors.join(', ')}" unless result.success?

      client
    end

    def initialize(workspace)
      @workspace = workspace
      super(root_dir: workspace.root)
      reset_budget
    end

    def reset_budget(limit = 64)
      raise ArgumentError, "tool budget must be a positive integer" unless limit.is_a?(Integer) && limit.positive?

      @remaining_calls = limit
    end

    def call_tool(name, arguments = {})
      raise UTCP::ToolCallError, "workspace tool-call budget exhausted" unless @remaining_calls.positive?

      @remaining_calls -= 1
      super
    end
  end
end
