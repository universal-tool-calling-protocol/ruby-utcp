# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

module UTCP
  class CLIProtocol < CommunicationProtocol
    PLACEHOLDER = /UTCP_ARG_([A-Za-z0-9_]+)_UTCP_END/.freeze
    DEFAULT_ENVIRONMENT = %w[
      PATH HOME LANG LANGUAGE LC_ALL LC_CTYPE TMPDIR TEMP TMP SHELL USER LOGNAME
    ].freeze

    def register_manual(client, template)
      assert_template!(template)
      output = execute(client, template, {})
      data = Utils.parse_document(output, source: "CLI output")
      data = { "utcp_version" => VERSION, "manual_version" => "1.0.0", "tools" => data } if data.is_a?(Array)
      data = Migration.manual_v0_1_to_v1_1(data) if Migration.v0_1_manual?(data)
      success(template, Manual.from_h(data))
    rescue StandardError => error
      client.logger.warn("Unable to register CLI manual #{template.name.inspect}: #{error.message}")
      failure(template, error)
    end

    def call_tool(client, tool_name, tool_args, template)
      assert_template!(template)
      output = execute(client, template, tool_args || {})
      stripped = output.strip
      if stripped.start_with?("{", "[")
        JSON.parse(stripped)
      else
        stripped
      end
    rescue JSON::ParserError
      output.strip
    rescue Error
      raise
    rescue StandardError => error
      raise ToolCallError.new("CLI tool #{tool_name.inspect} failed: #{error.message}", tool_name: tool_name)
    end

    private

    def assert_template!(template)
      return if template.is_a?(CliCallTemplate)

      raise ValidationError, "CLI protocol requires a CliCallTemplate"
    end

    def execute(client, template, arguments)
      env = environment_for(template)
      commands = template.commands.each_with_index.map do |step, index|
        command, argument_env = interpolate(step.command, arguments)
        env.merge!(argument_env)
        [command, include_output?(step, index, template.commands.length)]
      end
      script = build_script(commands)
      working_dir = template.working_dir ? File.expand_path(template.working_dir, client.root_dir) : client.root_dir
      raise ToolCallError, "CLI working directory does not exist: #{working_dir}" unless File.directory?(working_dir)

      run_script(script, env, working_dir, template.timeout)
    end

    def environment_for(template)
      names = template.inherit_env_vars.nil? ? DEFAULT_ENVIRONMENT : template.inherit_env_vars
      environment = names.each_with_object({}) do |name, selected|
        selected[name] = ENV[name] if ENV.key?(name)
      end
      template.env_vars.each { |name, value| environment[name] = value.to_s }
      environment
    end

    def interpolate(command, arguments)
      args = Utils.stringify_keys(arguments)
      env = {}
      result = +""
      quote = nil
      escaped = false
      index = 0
      variable_numbers = {}

      while index < command.length
        match = PLACEHOLDER.match(command, index)
        if match && match.begin(0) == index
          name = match[1]
          raise ToolCallError, "Missing required CLI argument: #{name}" unless args.key?(name)

          number = variable_numbers.fetch(name) { variable_numbers[name] = variable_numbers.length }
          variable = "UTCP_TOOL_ARG_#{number}"
          value = args[name]
          env[variable] = value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
          result << case quote
                    when "'" then %Q('"${#{variable}}"')
                    when '"' then "${#{variable}}"
                    else %Q("${#{variable}}")
                    end
          index = match.end(0)
          next
        end

        character = command[index]
        result << character
        if escaped
          escaped = false
        elsif character == "\\" && quote != "'"
          escaped = true
        elsif character == "'" && quote != '"'
          quote = quote == "'" ? nil : "'"
        elsif character == '"' && quote != "'"
          quote = quote == '"' ? nil : '"'
        end
        index += 1
      end
      [result, env]
    end

    def include_output?(step, index, length)
      step.append_to_final_output.nil? ? index == length - 1 : step.append_to_final_output
    end

    def build_script(commands)
      lines = []
      commands.each_with_index do |(command, append), index|
        lines << "__utcp_output_#{index}=$( { #{command}; } 2>&1 )"
        lines << "__utcp_status_#{index}=$?"
        lines << "CMD_#{index}_OUTPUT=$__utcp_output_#{index}"
        lines << "export CMD_#{index}_OUTPUT"
        lines << "printf '%s\\n' \"$__utcp_output_#{index}\"" if append
        lines << "if [ \"$__utcp_status_#{index}\" -ne 0 ]; then printf '%s\\n' \"$__utcp_output_#{index}\" >&2; exit \"$__utcp_status_#{index}\"; fi"
      end
      lines.join("\n")
    end

    def run_script(script, environment, working_dir, timeout_seconds)
      stdout_text = nil
      stderr_text = nil
      status = nil
      wait_thread = nil

      Open3.popen3(
        environment,
        "/bin/sh", "-c", script,
        unsetenv_others: true,
        chdir: working_dir,
        pgroup: true
      ) do |stdin, stdout, stderr, thread|
        wait_thread = thread
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        begin
          Timeout.timeout(timeout_seconds) do
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
            status = thread.value
          end
        rescue Timeout::Error
          terminate_process_group(thread.pid)
          stdout_reader.kill
          stderr_reader.kill
          raise TimeoutError, "CLI command timed out after #{timeout_seconds} seconds"
        end
      end

      unless status&.success?
        detail = stderr_text.to_s.strip
        detail = stdout_text.to_s.strip if detail.empty?
        raise ToolCallError.new("CLI command exited with status #{status&.exitstatus}: #{detail}", status: status&.exitstatus)
      end
      stdout_text.to_s
    ensure
      terminate_process_group(wait_thread.pid) if wait_thread&.alive?
    end

    def terminate_process_group(pid)
      Process.kill("TERM", -pid)
      sleep(0.05)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
  CliCommunicationProtocol = CLIProtocol
end

