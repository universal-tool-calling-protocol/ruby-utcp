# frozen_string_literal: true

require "json"
require_relative "workspace_tools"

module CodingAgent
  class ExecutionTrace
    FILE_TOOLS = %w[write_file append_file commit_file edit_file edit_file_batch rewrite_file move_file delete_file].freeze
    UNKNOWN_FILE = WorkspaceTools::UNKNOWN_FINGERPRINT

    def initialize(output, workspace: nil, require_current_reads: false)
      @output = output
      @root = File.realpath(workspace) if workspace
      @workspace = WorkspaceTools.new(@root) if @root
      @require_current_reads = require_current_reads
      reset
    end

    def reset
      @program = 0
      @step = 0
      @initial_files = {}
      @shell_snapshot = nil
      @scan_incomplete = false
      @known_files = {}
      @verified_changes = {}
      @read_count = 0
    end

    def program(code)
      @program += 1
      @step = 0
      write("Code Mode #{@program}: program", code)
    end

    def step(name, arguments, render: nil)
      @step += 1
      label = "Tool #{@program}.#{@step}: #{name}"
      write("#{label} arguments", arguments)
      arguments = arguments.transform_keys(&:to_s)
      check_current_reads(name, arguments) if @require_current_reads
      track_files(name, arguments)
      before = current_known_files if @require_current_reads && name == "workspace.run_command"
      result = yield(label)
      observe_result(name, arguments, result, before) if @require_current_reads
      write("#{label} output", render ? render.call(result) : result)
      result
    rescue StandardError => error
      write("#{label} error", error.message)
      raise
    end

    def completed(execution)
      write("Code Mode #{@program}: captured logs", execution.fetch("logs"))
      write("Code Mode #{@program}: result", execution.fetch("result"))
    end

    def failed(error)
      write("Code Mode request error", error.message)
      write("Code Mode #{@program}: captured logs", error.logs) if error.respond_to?(:logs)
    end

    def file_changes
      current = @workspace.workspace_fingerprints if @shell_snapshot
      if current
        note_scan_coverage(current)
        current.fetch("files").each_key do |path|
          next if @initial_files.key?(path)

          # An incomplete baseline cannot prove that a newly observed path
          # was absent before the shell command.
          @initial_files[path] = @shell_snapshot["complete"] ? nil : UNKNOWN_FILE
        end
      end
      @initial_files.keys.sort.each_with_object([]) do |path, changes|
        before = @initial_files[path]
        after = current ? current.fetch("files").fetch(path) { file_hash(path) } : file_hash(path)
        next if before.equal?(UNKNOWN_FILE) || after.equal?(UNKNOWN_FILE) || before == after

        status = before.nil? ? "created" : (after.nil? ? "deleted" : "modified")
        prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
        changes << { "path" => path.delete_prefix(prefix), "status" => status }
      end
    end

    def seed_context(context)
      context.fetch("files").each do |file|
        path = absolute_path(file["path"])
        next unless path && file["content"].is_a?(String)
        next unless Digest::SHA256.hexdigest(file["content"]) == file["sha256"]

        @known_files[path] = { sha256: file["sha256"], complete: true }
        @read_count += 1
      end
    end

    def completion_problem
      changes = file_changes
      return "No file changes observed (--require-changes)." if changes.empty?
      return "No file contents were read. Read the changed files to verify their current state." if @read_count.zero?

      verified = changes.any? do |change|
        path = absolute_path(change.fetch("path"))
        @verified_changes.key?(path) && @verified_changes[path] == file_hash(path)
      end
      return if verified

      "No change based on a current file read was verified. Read the relevant files, apply the requested edits, and verify them."
    end

    def report_file_changes
      changes = file_changes
      write("Workspace file changes", changes.empty? ? "No file-content changes observed in the tracked workspace." : changes)
      if @scan_incomplete
        write("Change tracking limits", "Some paths could not be fingerprinted or the scan was incomplete; changes outside the verified paths are unknown.")
      end
    end

    def write(label, value)
      @output.puts("\n[#{label}]")
      @output.puts(value.is_a?(String) ? value : JSON.pretty_generate(value))
      @output.flush
    end

    private

    def absolute_path(path)
      return unless path.is_a?(String) && !path.empty? && !path.include?("\0")

      expanded = File.expand_path(path, @root)
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      expanded if expanded.start_with?(prefix)
    end

    def check_current_reads(name, arguments)
      return unless name.start_with?("workspace.")

      tool = name.delete_prefix("workspace.")
      return unless FILE_TOOLS.include?(tool) && tool != "write_file"

      paths = [arguments["path"]]
      paths << arguments["draft_path"] if tool == "commit_file"
      paths.each do |relative|
        path = absolute_path(relative)
        known = @known_files[path]
        unless known
          raise ArgumentError, "Read #{relative.inspect} with read_file/read_files before modifying it; repository context also counts"
        end
        unless known[:sha256] == file_hash(path)
          raise ArgumentError, "File changed since it was read: #{relative}. Read it again and base the edit on its current content"
        end
        if %w[rewrite_file commit_file].include?(tool) && !known[:complete]
          raise ArgumentError, "Read all pages of #{relative} before replacing the complete file; follow next_line or use edit_file_batch for a focused edit"
        end
      end
    end

    def current_known_files
      @known_files.each_with_object({}) do |(path, known), files|
        files[path] = known[:sha256] if known[:sha256] == file_hash(path)
      end
    end

    def observe_result(name, arguments, result, before)
      if name == "workspace.run_command"
        before.each do |path, hash|
          after = file_hash(path)
          @verified_changes[path] = after if after != hash && !after.equal?(UNKNOWN_FILE)
        end
        return
      end
      return unless result.is_a?(Hash) && !result.key?("error")

      if name == "workspace.read_file"
        observe_page(arguments["path"], arguments["start_line"], result)
      elsif name == "workspace.read_files"
        requests = arguments["files"]
        result.fetch("files").zip(requests).each do |page, request|
          observe_page(page["path"], request.fetch("start_line", request.fetch(:start_line, 1)), page)
        end
      elsif name.start_with?("workspace.") && FILE_TOOLS.include?(name.delete_prefix("workspace."))
        path = absolute_path(arguments["path"])
        after = file_hash(path)
        known = @known_files[path]
        # A no-op must not validate an earlier unrelated or unread shell edit.
        @verified_changes[path] = after if (!known || known[:sha256] != after) && !after.equal?(UNKNOWN_FILE)
        case name
        when "workspace.move_file"
          destination = absolute_path(arguments["destination_path"])
          @known_files[destination] = known
          @known_files.delete(path)
          @verified_changes[destination] = file_hash(destination)
        when "workspace.delete_file"
          @known_files.delete(path)
        when "workspace.commit_file"
          @known_files.delete(absolute_path(arguments["draft_path"]))
          @known_files[path] = { sha256: after, complete: true }
        else
          complete = %w[workspace.write_file workspace.rewrite_file].include?(name) ||
                     (name == "workspace.append_file" && known && known[:complete])
          @known_files[path] = { sha256: after, complete: complete }
        end
      end
    end

    def observe_page(relative, start_line, result)
      return if result.key?("error") || !result["sha256"].is_a?(String)

      path = absolute_path(relative)
      return unless path

      known = @known_files[path]
      known = { sha256: result["sha256"], complete: false } unless known && known[:sha256] == result["sha256"]
      first = Integer(start_line)
      count = result.fetch("returned_lines")
      # An empty page beyond EOF is not evidence of reading a nonempty file.
      return if count.zero? && result.fetch("total_lines").positive?

      ranges = (known[:ranges] ||= [])
      ranges << [first, first + count]
      next_line = 1
      ranges.sort.each do |range_start, range_end|
        break if range_start > next_line

        next_line = [next_line, range_end].max
      end
      known[:complete] ||= next_line > result.fetch("total_lines")
      @known_files[path] = known
      @read_count += 1
    end

    def track_files(name, arguments)
      if @workspace && name == "workspace.run_command"
        unless @shell_snapshot
          @shell_snapshot = @workspace.workspace_fingerprints
          note_scan_coverage(@shell_snapshot)
          @shell_snapshot.fetch("files").each do |path, fingerprint|
            @initial_files[path] = fingerprint unless @initial_files.key?(path)
          end
        end
        return
      end
      return unless @workspace && name.start_with?("workspace.") && FILE_TOOLS.include?(name.delete_prefix("workspace."))

      arguments = arguments.transform_keys(&:to_s)
      keys = ["path"]
      keys << "destination_path" if name == "workspace.move_file"
      keys << "draft_path" if name == "workspace.commit_file"
      keys.each do |key|
        relative = arguments[key]
        next unless relative.is_a?(String) && !relative.empty? && !relative.include?("\0")

        path = File.expand_path(relative, @root)
        prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
        next unless path.start_with?(prefix)
        next if @initial_files.key?(path)

        excluded = path.delete_prefix(prefix).split(File::SEPARATOR).any? do |component|
          WorkspaceTools::HIDDEN_DIRECTORIES.include?(component)
        end
        @initial_files[path] = if @shell_snapshot
                                @shell_snapshot["complete"] && !excluded ? nil : UNKNOWN_FILE
                              else
                                file_hash(path)
                              end
        @scan_incomplete = true if @initial_files[path].equal?(UNKNOWN_FILE)
      end
    end

    def note_scan_coverage(snapshot)
      @scan_incomplete ||= !snapshot.fetch("complete") || snapshot.fetch("files").value?(UNKNOWN_FILE)
    end

    def file_hash(path)
      @workspace.file_fingerprint(path)
    rescue ArgumentError, SystemCallError
      # Missing files are distinguishable from unreadable/unsupported files.
      # Only a verifiable before/after difference counts as an edit.
      UNKNOWN_FILE
    end
  end

  # Extend only this example's client, so every real tool call within a program
  # is visible even when the program discards or summarizes that tool's result.
  module ToolTracing
    attr_accessor :execution_trace

    def call_tool(name, arguments = {})
      return super unless execution_trace

      execution_trace.step(name, arguments) { super }
    end

    def call_tool_streaming(name, arguments = {})
      return enum_for(__method__, name, arguments) unless block_given?
      return super { |chunk| yield chunk } unless execution_trace

      execution_trace.step(name, arguments) do |label|
        super do |chunk|
          execution_trace.write("#{label} chunk", chunk)
          yield chunk
        end
      end
    end

    def search_tools(query, **options)
      return super unless execution_trace

      execution_trace.step("codemode.search_tools", { "query" => query }.merge(options),
                           render: ->(tools) { tools.map(&:to_h) }) { super }
    end
  end
end
