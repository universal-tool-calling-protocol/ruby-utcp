# frozen_string_literal: true

require "json"
require "optparse"
require_relative "coding_agent/agent"
require_relative "coding_agent/llm"

module RubyUTCPAgent
  class CLI
    def initialize(input: $stdin, output: $stdout, error: $stderr, env: ENV)
      @input, @output, @error, @env = input, output, error, env
    end

    def run(argv)
      options = { workspace: Dir.pwd, model: @env["OPENROUTER_MODEL"] || @env["LLM_MODEL"],
                  base_url: @env.fetch("UTCP_AGENT_BASE_URL", LLM::DEFAULT_BASE_URL), max_turns: 12 }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby -Ilib examples/coding_agent.rb [options] [task]"
        opts.on("--workspace DIR", "Workspace directory (default: current directory)") { |v| options[:workspace] = v }
        opts.on("--model ID", "Tool-capable model ID (or OPENROUTER_MODEL)") { |v| options[:model] = v }
        opts.on("--base-url URL", "Chat-completions API base URL") { |v| options[:base_url] = v }
        opts.on("--prompt TASK", "Run one task, then exit") { |v| options[:prompt] = v }
        opts.on("--max-turns N", Integer, "LLM iterations per task (default: 12)") { |v| options[:max_turns] = v }
        opts.on("--codemode", "Expose restricted Ruby tool-chain execution") { options[:codemode] = true }
        opts.on("--read-only", "Deny all file edits and command execution") { options[:read_only] = true }
        opts.on("--yes", "Auto-approve edits AND arbitrary commands; trusted workspaces only") { options[:yes] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
      end
      remaining = parser.parse(argv.dup)
      if options[:help]
        @output.puts(parser)
        return 0
      end
      raise ArgumentError, "use --prompt or a positional task, not both" if options[:prompt] && !remaining.empty?

      options[:prompt] ||= remaining.join(" ") unless remaining.empty?
      llm = LLM.new(api_key: @env["LLM_API_KEY"] || @env["OPENROUTER_API_KEY"],
                    model: options[:model], base_url: options[:base_url])
      unless options[:prompt] || @input.tty?
        raise ArgumentError, "interactive mode requires a terminal; pass --prompt for a single task"
      end
      $LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
      require_relative "coding_agent/utcp_workspace"
      @options = options
      workspace = Workspace.new(root: options[:workspace], approve: method(:approve), read_only: options[:read_only])
      client = WorkspaceClient.build(workspace)
      code_mode = options[:codemode] ? UTCP::CodeMode.new(client) : nil
      agent = Agent.new(client: client, llm: llm, code_mode: code_mode, max_turns: options[:max_turns],
                        on_event: ->(event) { @error.puts(safe_text(event)) })
      @error.puts("Workspace: #{workspace.root.to_json}")
      @error.puts("Source/tool output will be sent to the configured LLM provider. Review changes before committing.")
      if options[:yes] && !options[:read_only]
        @error.puts("WARNING: --yes permits file edits and arbitrary commands without confirmation. This is not a sandbox.")
      end
      return show_result(agent.run(options[:prompt])) if options[:prompt]

      @output.puts("Ruby UTCP coding agent. Type a task, /reset, or /exit.")
      loop do
        @output.print("> ")
        @output.flush
        line = @input.gets
        break if line.nil? || %w[/exit /quit].include?(line.strip)
        next if line.strip.empty?

        if line.strip == "/reset"
          agent.reset
          @output.puts("Conversation cleared.")
          next
        end
        begin
          show_result(agent.run(line.strip))
        rescue StandardError => error
          @error.puts("Error: #{safe_text(error.message)}")
        end
      end
      0
    rescue Interrupt
      @error.puts("Interrupted. Completed edits are not rolled back; review the workspace.")
      130
    rescue LoadError => error
      @error.puts("Unable to load ruby-utcp. Run from the repository with ruby -Ilib, or install the gem. #{safe_text(error.message)}")
      1
    rescue StandardError => error
      @error.puts("Error: #{safe_text(error.message)}")
      1
    ensure
      client.close if defined?(client) && client
    end

    private

    def show_result(result)
      @output.puts(safe_text(result.answer))
      result.status == "completed" ? 0 : 2
    end

    def approve(name, details)
      return true if @options[:yes]
      unless @input.tty?
        @error.puts("Denied #{name}: approval requires an interactive terminal (or explicit --yes).")
        return false
      end
      preview = details.each_with_object({}) do |(key, value), data|
        data[key] = if value.is_a?(String) && value.bytesize > 4000
                      value.byteslice(0, 4000).force_encoding(Encoding::UTF_8).scrub("") + "\n[PREVIEW TRUNCATED; #{value.bytesize} bytes total]"
                    else
                      value
                    end
      end
      @error.puts("\nApproval required: #{name}")
      @error.puts(JSON.pretty_generate(preview))
      @error.print("Apply this operation? [y/N] ")
      @error.flush
      %w[y yes].include?(@input.gets.to_s.strip.downcase)
    end

    def safe_text(text)
      text.to_s.gsub(/[\x00-\x08\x0B-\x1F\x7F]/) { |char| format("\\u%04x", char.ord) }
    end
  end
end

exit RubyUTCPAgent::CLI.new.run(ARGV) if $PROGRAM_NAME == __FILE__
