# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"

module CodingAgent
  # This file is also the executable behind the manual's CLI call templates.
  class WorkspaceTools
    MAX_FILE_BYTES = 256 * 1024
    MAX_OUTPUT_BYTES = 32 * 1024
    MAX_READ_LINES = 50_000
    MAX_ENTRIES = 200
    HIDDEN_DIRECTORIES = %w[.git .bundle node_modules vendor .venv].freeze
    PATH_INPUT = { "type" => "string", "description" => "Path relative to the workspace; use . for its root." }.freeze
    TEXT_INPUT = { "type" => "string" }.freeze
    DEFINITIONS = {
      "list_files" => {
        "description" => "List one directory, up to 200 entries. Directory names end with /. Start with path '.'.",
        "properties" => { "path" => PATH_INPUT }
      },
      "read_file" => {
        "description" => "Read a UTF-8 file page with line numbers and its full-file sha256. start_line is one-based, max_lines accepts 1 to 50000. Output is bounded to 32 KiB; follow next_line for the rest.",
        "properties" => {
          "path" => PATH_INPUT,
          "start_line" => { "type" => "integer", "minimum" => 1 },
          "max_lines" => { "type" => "integer", "minimum" => 1, "maximum" => MAX_READ_LINES }
        }
      },
      "write_file" => {
        "description" => "Create a new UTF-8 file, including parent directories. Fails if it already exists. For a long rewrite, create a draft here, then append_file and commit_file. Returns total_bytes.",
        "properties" => { "path" => PATH_INPUT, "content" => TEXT_INPUT }
      },
      "append_file" => {
        "description" => "Append a small chunk to an existing UTF-8 draft. Set expected_bytes to the previous write/append total_bytes; a mismatch prevents duplicate or stale appends. Returns total_bytes.",
        "properties" => { "path" => PATH_INPUT, "content" => TEXT_INPUT,
                          "expected_bytes" => { "type" => "integer", "minimum" => 0 } }
      },
      "commit_file" => {
        "description" => "Atomically replace an existing file with a completed draft and remove the draft path. Use the original sha256 from read_file as expected_sha256. Fails if the original changed. Review the draft first.",
        "properties" => { "path" => PATH_INPUT, "draft_path" => PATH_INPUT, "expected_sha256" => TEXT_INPUT }
      },
      "edit_file" => {
        "description" => "Replace one exact occurrence of old_text with new_text. Read the file first. Fails if old_text is empty, missing, or ambiguous.",
        "properties" => { "path" => PATH_INPUT, "old_text" => TEXT_INPUT, "new_text" => TEXT_INPUT }
      },
      "run_command" => {
        "description" => "Run a shell command in the workspace (for example, tests or git diff). Returns exit_code and bounded output. Times out after 60 seconds.",
        "properties" => { "command" => TEXT_INPUT }
      }
    }.freeze

    def initialize(root = Dir.pwd)
      @root = File.realpath(root)
      raise ArgumentError, "Workspace must be a directory" unless File.directory?(@root)
    end

    def call(name, *arguments)
      raise ArgumentError, "Unknown workspace tool: #{name}" unless DEFINITIONS.key?(name)

      public_send(name, *arguments)
    end

    def list_files(path)
      directory = workspace_path(path)
      entries = Dir.children(directory).reject { |entry| HIDDEN_DIRECTORIES.include?(entry) }.sort
      {
        "entries" => entries.first(MAX_ENTRIES).map do |entry|
          full_path = File.join(directory, entry)
          suffix = File.symlink?(full_path) ? " (symlink)" : (File.directory?(full_path) ? "/" : "")
          entry + suffix
        end,
        "truncated" => entries.length > MAX_ENTRIES
      }
    end

    def read_file(path, start_line, max_lines)
      first = Integer(start_line)
      count = Integer(max_lines)
      unless first.positive? && (1..MAX_READ_LINES).cover?(count)
        raise ArgumentError, "start_line must be positive and max_lines must be between 1 and #{MAX_READ_LINES}"
      end

      text = read_text(workspace_path(path))
      lines = text.lines
      selected = lines.slice(first - 1, count) || []
      content = +""
      returned_lines = 0
      selected.each_with_index do |line, index|
        numbered = "#{first + index}: #{line}"
        if content.bytesize + numbered.bytesize > MAX_OUTPUT_BYTES
          raise ArgumentError, "Line #{first} exceeds 32 KiB and cannot fit in a read_file page" if content.empty?

          break
        end
        content << numbered
        returned_lines += 1
      end

      following = first + returned_lines
      { "content" => content, "total_lines" => lines.length, "next_line" => following <= lines.length ? following : nil,
        "returned_lines" => returned_lines, "truncated" => returned_lines < selected.length,
        "sha256" => Digest::SHA256.hexdigest(text) }
    end

    def write_file(path, content)
      validate_text!(content)
      destination = workspace_path(path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(content) }
      { "path" => path, "bytes_written" => content.bytesize, "total_bytes" => content.bytesize }
    end

    def append_file(path, content, expected_bytes)
      validate_text!(content)
      destination = workspace_path(path)
      raise ArgumentError, "Expected an existing regular file" unless File.file?(destination)

      total = nil
      File.open(destination, "r+b") do |file|
        file.flock(File::LOCK_EX)
        current = file.read(MAX_FILE_BYTES + 1).force_encoding(Encoding::UTF_8)
        validate_text!(current)
        unless current.bytesize == Integer(expected_bytes)
          raise ArgumentError, "File size changed; read the draft before retrying this append"
        end
        validate_text!(current + content)
        file.write(content)
        total = current.bytesize + content.bytesize
      end
      { "path" => path, "bytes_written" => content.bytesize, "total_bytes" => total }
    end

    def commit_file(path, draft_path, expected_sha256)
      destination = workspace_path(path)
      draft = workspace_path(draft_path)
      original = read_text(destination)
      replacement = read_text(draft)
      raise ArgumentError, "Draft and original must be different files" if File.identical?(destination, draft)
      unless Digest::SHA256.hexdigest(original) == expected_sha256
        raise ArgumentError, "Original file changed; read it again and reconcile the draft before committing"
      end

      # Keep the original's permissions. The draft should be beside it so rename
      # is atomic on the same filesystem; a cross-device rename fails unchanged.
      File.chmod(File.stat(destination).mode & 0o777, draft)
      File.rename(draft, destination)
      { "path" => path, "bytes_written" => replacement.bytesize, "sha256" => Digest::SHA256.hexdigest(replacement) }
    end

    def edit_file(path, old_text, new_text)
      raise ArgumentError, "old_text must not be empty" if old_text.empty?

      destination = workspace_path(path)
      content = read_text(destination)
      offset = content.index(old_text)
      raise ArgumentError, "old_text was not found" unless offset
      raise ArgumentError, "old_text matches more than once; include more surrounding text" if content.index(old_text, offset + 1)

      updated = content.dup
      updated[offset, old_text.length] = new_text
      validate_text!(updated)
      File.binwrite(destination, updated)
      { "path" => path, "bytes_written" => updated.bytesize }
    end

    def run_command(command)
      raise ArgumentError, "command must not be empty" if command.strip.empty?

      output = +"".b
      truncated = false
      status = nil
      # The UTCP CLI transport owns the process group and the 60-second timeout.
      Open3.popen2e("/bin/sh", "-c", command, chdir: @root) do |stdin, stream, waiter|
        stdin.close
        begin
          loop do
            chunk = stream.readpartial(4096)
            remaining = MAX_OUTPUT_BYTES - output.bytesize
            output << chunk.byteslice(0, remaining)
            truncated ||= chunk.bytesize > remaining
          end
        rescue EOFError
          status = waiter.value
        end
      end
      { "output" => output.force_encoding(Encoding::UTF_8).scrub, "exit_code" => status.exitstatus,
        "signal" => status.termsig, "truncated" => truncated }
    end

    private

    def workspace_path(path)
      raise ArgumentError, "path must not be empty" if path.empty?

      expanded = File.expand_path(path, @root)
      prefix = @root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR
      unless expanded == @root || expanded.start_with?(prefix)
        raise ArgumentError, "Path must stay inside the workspace"
      end

      relative = expanded == @root ? "" : expanded.delete_prefix(prefix)
      current = @root
      relative.split(File::SEPARATOR).each do |component|
        raise ArgumentError, "The .git directory is not available to file tools" if component == ".git"

        current = File.join(current, component)
        raise ArgumentError, "File tools do not follow symlinks" if File.symlink?(current)
      end
      expanded
    end

    def read_text(path)
      raise ArgumentError, "Expected a regular file" unless File.file?(path)

      content = File.binread(path, MAX_FILE_BYTES + 1).force_encoding(Encoding::UTF_8)
      validate_text!(content)
      content
    end

    def validate_text!(content)
      raise ArgumentError, "File exceeds 256 KiB" if content.bytesize > MAX_FILE_BYTES
      raise ArgumentError, "Only UTF-8 text files are supported" unless content.valid_encoding? && !content.include?("\0")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    name = ARGV.shift
    puts JSON.generate(CodingAgent::WorkspaceTools.new.call(name, *ARGV))
  rescue StandardError => error
    # Return errors as tool results so the model can correct its next call.
    puts JSON.generate("error" => error.message)
  end
end
