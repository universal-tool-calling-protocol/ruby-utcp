# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "tempfile"
require_relative "ruby_symbols"

module CodingAgent
  # This file is also the executable behind the manual's CLI call templates.
  class WorkspaceTools
    MAX_FILE_BYTES = 256 * 1024
    MAX_OUTPUT_BYTES = 32 * 1024
    MAX_READ_LINES = 50_000
    MAX_ENTRIES = 200
    MAX_BATCH_FILES = 8
    MAX_BATCH_EDITS = 50
    MAX_SCAN_ENTRIES = 20_000
    MAX_SEARCH_BYTES = 32 * 1024 * 1024
    MAX_PATTERN_BYTES = 1024
    GREP_MATCH_TIMEOUT = 0.05
    GREP_TIMEOUT = 2
    UNKNOWN_FINGERPRINT = false
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
      "find_files" => {
        "description" => "Find files recursively without shell access. glob matches paths relative to path, or any basename when it has no /. Use path '.', glob '**/*', offset 0 to start; follow next_offset. Skips dependency directories and symlinks; scan_truncated means narrow the path/glob.",
        "properties" => { "path" => PATH_INPUT, "glob" => TEXT_INPUT,
                          "offset" => { "type" => "integer", "minimum" => 0 } }
      },
      "search_files" => {
        "description" => "Search UTF-8 files recursively for literal, case-sensitive query text. Returns matching lines with workspace-relative paths and line numbers. Use path '.', glob '**/*', offset 0; follow next_offset. Bounded scan skips dependency directories, symlinks, binary and oversized files; inspect skipped_files and scan_truncated.",
        "properties" => { "path" => PATH_INPUT, "query" => TEXT_INPUT, "glob" => TEXT_INPUT,
                          "offset" => { "type" => "integer", "minimum" => 0 } }
      },
      "grep" => {
        "description" => "Search text files with a Ruby regular expression (Ruby 3.2+). Returns one match per line with path, line number and excerpt. path accepts a file or directory. Use glob '*.rb', ignore_case false, offset 0; follow next_offset. Matching is time-limited; narrow the path/glob or simplify the pattern on timeout. Use search_files for literal text.",
        "properties" => { "path" => PATH_INPUT, "pattern" => TEXT_INPUT, "glob" => TEXT_INPUT,
                          "ignore_case" => { "type" => "boolean" },
                          "offset" => { "type" => "integer", "minimum" => 0 } }
      },
      "symbols" => {
        "description" => "Find Ruby class, module, method and constant declarations using the parser, without running source. Returns names, lexical qualified names, kinds, paths and one-based lines. path accepts a file or directory. Use query '' for all or a case-sensitive name substring, glob '*.rb', offset 0; follow next_offset. Supports .rb/.rake/.gemspec/.ru, Gemfile and Rakefile. Check parse_errors, unsupported_files, skipped_files and scan_truncated; dynamic definitions are not indexed. Use grep for references or other languages.",
        "properties" => { "path" => PATH_INPUT, "query" => TEXT_INPUT, "glob" => TEXT_INPUT,
                          "offset" => { "type" => "integer", "minimum" => 0 } }
      },
      "read_files" => {
        "description" => "Read up to 8 independent file pages in one process. Each item requires path, with optional start_line (default 1) and max_lines (default 200). Shares a 32 KiB content budget; follow each next_line with read_file. Errors are returned per file.",
        "properties" => { "files" => { "type" => "array", "minItems" => 1, "maxItems" => MAX_BATCH_FILES,
          "items" => { "type" => "object", "properties" => {
            "path" => PATH_INPUT, "start_line" => { "type" => "integer", "minimum" => 1 },
            "max_lines" => { "type" => "integer", "minimum" => 1, "maximum" => MAX_READ_LINES }
          }, "required" => ["path"], "additionalProperties" => false } } }
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
      "edit_file_batch" => {
        "description" => "Apply up to 50 exact replacements to one file in order, then atomically save once. All replacements must succeed or the file stays unchanged. Requires expected_sha256 from read_file/read_files. Each old_text must be nonempty and unique in the text at that step. Returns the new sha256.",
        "properties" => { "path" => PATH_INPUT, "expected_sha256" => TEXT_INPUT,
          "edits" => { "type" => "array", "minItems" => 1, "maxItems" => MAX_BATCH_EDITS,
            "items" => { "type" => "object", "properties" => { "old_text" => TEXT_INPUT, "new_text" => TEXT_INPUT },
                         "required" => %w[old_text new_text], "additionalProperties" => false } } }
      },
      "rewrite_file" => {
        "description" => "Atomically replace an existing UTF-8 file with new content, preserving permissions. Requires expected_sha256 from a read or repository snapshot. For long content, use a draft with append_file and commit_file instead.",
        "properties" => { "path" => PATH_INPUT, "content" => TEXT_INPUT, "expected_sha256" => TEXT_INPUT }
      },
      "move_file" => {
        "description" => "Move or rename one UTF-8 file, creating parent directories and preserving permissions. Requires the source expected_sha256. Refuses to overwrite any destination. Update references separately and inspect each result.",
        "properties" => { "path" => PATH_INPUT, "destination_path" => PATH_INPUT, "expected_sha256" => TEXT_INPUT }
      },
      "delete_file" => {
        "description" => "Delete one UTF-8 file after reading it. Requires its expected_sha256; a changed file is left intact. Does not delete directories.",
        "properties" => { "path" => PATH_INPUT, "expected_sha256" => TEXT_INPUT }
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
      read_page(path, start_line, max_lines, MAX_OUTPUT_BYTES)
    end

    # Host-side context loading uses the same path and text checks as tools,
    # without line prefixes or the per-tool output-page limit.
    def read_snapshot(path)
      content = read_text(workspace_path(path))
      { "path" => path, "content" => content, "sha256" => Digest::SHA256.hexdigest(content) }
    end

    def file_fingerprint(path)
      destination = workspace_path(path)
      begin
        stat = File.lstat(destination)
      rescue Errno::ENOENT
        return nil
      end
      raise ArgumentError, "Expected a regular file" unless stat.file?
      raise ArgumentError, "File exceeds 256 KiB" if stat.size > MAX_FILE_BYTES

      content = File.binread(destination, MAX_FILE_BYTES + 1) || +""
      raise ArgumentError, "File exceeds 256 KiB" if content.bytesize > MAX_FILE_BYTES

      Digest::SHA256.hexdigest(content)
    end

    # Host-side change tracking only: no file contents are sent to the model.
    # false marks a file whose fingerprint could not be established; nil is
    # reserved for a path that is known not to exist.
    def workspace_fingerprints
      files = {}
      bytes = 0
      state = { "scan_truncated" => false, "skipped_files" => 0, "scanned_entries" => 0 }
      each_workspace_file(@root, state) do |absolute, _relative|
        begin
          size = File.size(absolute)
          if size > MAX_FILE_BYTES
            files[absolute] = UNKNOWN_FINGERPRINT
            next
          end
          if bytes + size > MAX_SEARCH_BYTES
            state["scan_truncated"] = true
            break
          end
          bytes += size
          files[absolute] = file_fingerprint(absolute)
        rescue ArgumentError, SystemCallError
          files[absolute] = UNKNOWN_FINGERPRINT
        end
      end
      { "files" => files, "complete" => !state["scan_truncated"] && state["skipped_files"].zero? }
    end

    def read_files(files)
      requests = array_argument(files, MAX_BATCH_FILES, "files")
      budget = MAX_OUTPUT_BYTES / requests.length
      results = requests.map do |request|
        begin
          unless request.is_a?(Hash) && (request.keys - %w[path start_line max_lines]).empty? && request["path"].is_a?(String)
            raise ArgumentError, "Each file must have a path and optional start_line/max_lines"
          end

          read_page(request["path"], request.fetch("start_line", 1), request.fetch("max_lines", 200), budget)
            .merge("path" => request["path"])
        rescue ArgumentError, TypeError, SystemCallError => error
          { "path" => request.is_a?(Hash) ? request["path"] : nil, "error" => error.message }
        end
      end
      { "files" => results }
    end

    def find_files(path, glob, offset)
      scan_files(path, glob, offset)
    end

    def search_files(path, query, glob, offset)
      unless query.is_a?(String) && !query.empty? && !query.include?("\n") && !query.include?("\0")
        raise ArgumentError, "query must be nonempty literal text on one line"
      end

      scan_files(path, glob, offset, "matches") do |text, relative, accept|
        text.each_line.with_index(1) do |line, number|
          position = line.index(query)
          accept.call(matching_line(relative, line, number, position)) if position
        end
      end
    end

    def grep(path, pattern, glob, ignore_case, offset)
      unless pattern.is_a?(String) && !pattern.empty? && pattern.bytesize <= MAX_PATTERN_BYTES &&
             !pattern.include?("\n") && !pattern.include?("\0")
        raise ArgumentError, "pattern must be a nonempty, single-line regex of at most #{MAX_PATTERN_BYTES} bytes"
      end
      unless [true, false, "true", "false"].include?(ignore_case)
        raise ArgumentError, "ignore_case must be true or false"
      end
      # Older Ruby regex engines cannot interrupt every pathological pattern.
      # Keep literal search available there instead of accepting an unbounded regex.
      unless Regexp.respond_to?(:timeout)
        raise ArgumentError, "grep requires Ruby 3.2+ for regex timeouts; use search_files for literal text"
      end
      flags = [true, "true"].include?(ignore_case) ? Regexp::IGNORECASE : 0
      begin
        expression = Regexp.new(pattern, flags, timeout: GREP_MATCH_TIMEOUT)
      rescue RegexpError => error
        raise ArgumentError, "Invalid grep pattern: #{error.message}"
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GREP_TIMEOUT
      begin
        scan_files(path, glob, offset, "matches") do |text, relative, accept|
          text.each_line.with_index(1) do |line, number|
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise ArgumentError, "grep search timed out; narrow the path/glob or simplify the pattern"
            end
            match = expression.match(line)
            accept.call(matching_line(relative, line, number, match.begin(0))) if match
          end
        end
      rescue Regexp::TimeoutError
        raise ArgumentError, "grep match timed out; simplify the pattern"
      end
    end

    def symbols(path, query, glob, offset)
      unless query.is_a?(String) && query.bytesize <= MAX_PATTERN_BYTES && !query.include?("\n") && !query.include?("\0")
        raise ArgumentError, "query must be single-line literal text of at most #{MAX_PATTERN_BYTES} bytes (or empty for all symbols)"
      end
      stats = { "parse_errors" => 0, "unsupported_files" => 0 }
      filter = lambda do |relative|
        supported = %w[.rb .rake .gemspec .ru].include?(File.extname(relative)) ||
                    %w[Gemfile Rakefile].include?(File.basename(relative))
        stats["unsupported_files"] += 1 unless supported
        supported
      end
      result = scan_files(path, glob, offset, "symbols", file_filter: filter) do |text, relative, accept|
        begin
          RubySymbols.each(text) do |symbol|
            next unless symbol.fetch("qualified_name").include?(query)

            accept.call(symbol.merge("path" => relative))
          end
        rescue RubySymbols::ParseError
          stats["parse_errors"] += 1
        end
      end
      result["skipped_files"] += stats["parse_errors"]
      result.merge(stats)
    end

    def edit_file_batch(path, expected_sha256, edits)
      replacements = array_argument(edits, MAX_BATCH_EDITS, "edits")
      destination = workspace_path(path)
      original = read_text(destination)
      unless Digest::SHA256.hexdigest(original) == expected_sha256
        raise ArgumentError, "File changed; read it again before applying these edits"
      end

      updated = original
      replacements.each_with_index do |edit, index|
        unless edit.is_a?(Hash) && edit.keys.sort == %w[new_text old_text] && edit.values.all? { |value| value.is_a?(String) }
          raise ArgumentError, "Edit #{index + 1} requires old_text and new_text strings"
        end

        begin
          updated = replace_text(updated, edit["old_text"], edit["new_text"])
        rescue ArgumentError => error
          raise ArgumentError, "Edit #{index + 1}: #{error.message}"
        end
      end

      atomic_replace(path, destination, original, updated)
      { "path" => path, "edits_applied" => replacements.length, "bytes_written" => updated.bytesize,
        "sha256" => Digest::SHA256.hexdigest(updated) }
    end

    def rewrite_file(path, content, expected_sha256)
      validate_text!(content)
      destination, original = checked_file(path, expected_sha256)
      atomic_replace(path, destination, original, content)
      { "path" => path, "bytes_written" => content.bytesize, "sha256" => Digest::SHA256.hexdigest(content) }
    end

    def move_file(path, destination_path, expected_sha256)
      source, content = checked_file(path, expected_sha256)
      destination = workspace_path(destination_path)
      raise ArgumentError, "Destination already exists" if File.exist?(destination)

      FileUtils.mkdir_p(File.dirname(destination))
      # link fails atomically if the destination exists; rename would overwrite
      # a file created after the existence check. Cross-device moves fail intact.
      File.link(source, destination)
      File.unlink(source)
      { "path" => path, "destination_path" => destination_path, "sha256" => Digest::SHA256.hexdigest(content) }
    end

    def delete_file(path, expected_sha256)
      destination, = checked_file(path, expected_sha256)
      File.unlink(destination)
      { "path" => path, "deleted" => true }
    end

    def read_page(path, start_line, max_lines, budget)
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
        if content.bytesize + numbered.bytesize > budget
          raise ArgumentError, "Line #{first} exceeds the #{budget}-byte page budget; use read_file for a larger batch page" if content.empty?

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
        current = (file.read(MAX_FILE_BYTES + 1) || +"").force_encoding(Encoding::UTF_8)
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
      destination = workspace_path(path)
      content = read_text(destination)
      updated = replace_text(content, old_text, new_text)
      atomic_replace(path, destination, content, updated)
      { "path" => path, "bytes_written" => updated.bytesize, "sha256" => Digest::SHA256.hexdigest(updated) }
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

    def checked_file(path, expected_sha256)
      destination = workspace_path(path)
      content = read_text(destination)
      unless Digest::SHA256.hexdigest(content) == expected_sha256
        raise ArgumentError, "File changed; read it again before modifying it"
      end
      [destination, content]
    end

    def atomic_replace(path, destination, original, updated)
      Tempfile.create([".coding-agent-", ".tmp"], File.dirname(destination)) do |file|
        file.binmode
        file.write(updated)
        file.flush
        File.chmod(File.stat(destination).mode & 0o777, file.path)
        unless read_text(workspace_path(path)) == original
          raise ArgumentError, "File changed while preparing edits; read it again"
        end
        File.rename(file.path, destination)
      end
    end

    def array_argument(value, limit, name)
      value = JSON.parse(value) if value.is_a?(String)
      unless value.is_a?(Array) && (1..limit).cover?(value.length)
        raise ArgumentError, "#{name} must be an array of 1 to #{limit} items"
      end
      value
    end

    def replace_text(content, old_text, new_text)
      raise ArgumentError, "old_text must not be empty" if old_text.empty?

      offset = content.index(old_text)
      raise ArgumentError, "old_text was not found" unless offset
      raise ArgumentError, "old_text matches more than once; include more surrounding text" if content.index(old_text, offset + 1)

      updated = content.dup
      updated[offset, old_text.length] = new_text
      validate_text!(updated)
      updated
    end

    def matching_line(path, line, number, position)
      # Show the match even when it occurs late in a very long line.
      content = line.chomp
      excerpt = content[[position - 120, 0].max, 1000].to_s.byteslice(0, 1000)
                       .force_encoding(Encoding::UTF_8).scrub("")
      { "path" => path, "line" => number, "text" => excerpt,
        "text_truncated" => content.bytesize > excerpt.bytesize }
    end

    def scan_files(path, glob, offset, result_key = "files", file_filter: nil)
      target = workspace_path(path)
      unless File.directory?(target) || File.file?(target)
        raise ArgumentError, "Expected a file or directory"
      end
      raise ArgumentError, "glob must not be empty" unless glob.is_a?(String) && !glob.empty?

      offset = Integer(offset)
      raise ArgumentError, "offset must not be negative" if offset.negative?

      state = { "scan_truncated" => false, "skipped_files" => 0, "scanned_entries" => 0 }
      results = []
      matched = 0
      output_bytes = 2 # JSON array brackets, in addition to each item and comma.
      searched_bytes = 0
      more = false
      catch(:page_full) do
        each_workspace_file(target, state) do |absolute, relative|
          relative = File.basename(absolute) if relative.empty?
          candidate = glob.include?("/") ? relative : File.basename(relative)
          next unless File.fnmatch?(glob, candidate, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)

          workspace_relative = absolute.delete_prefix(@root.end_with?("/") ? @root : @root + "/")
          if file_filter && !file_filter.call(workspace_relative)
            state["skipped_files"] += 1
            next
          end
          accept = lambda do |item|
            matched += 1
            next if matched <= offset

            size = JSON.generate(item).bytesize + 1
            raise ArgumentError, "A search result exceeds 32 KiB; read the file directly" if size + 2 > MAX_OUTPUT_BYTES

            if results.length >= MAX_ENTRIES || output_bytes + size > MAX_OUTPUT_BYTES
              more = true
              throw :page_full
            end
            results << item
            output_bytes += size
          end
          unless block_given?
            accept.call(workspace_relative)
            next
          end

          begin
            size = File.size(absolute)
            if size > MAX_FILE_BYTES
              state["skipped_files"] += 1
              next
            end
            if searched_bytes + size > MAX_SEARCH_BYTES
              state["scan_truncated"] = true
              break
            end
            # Resolve again just before reading, including all ancestors.
            searched_bytes += size
            text = read_text(workspace_path(workspace_relative))
          rescue ArgumentError, SystemCallError
            state["skipped_files"] += 1
            next
          end
          yield text, workspace_relative, accept
        end
      end
      state.merge(result_key => results, "truncated" => more || state["scan_truncated"],
                  "next_offset" => more ? offset + results.length : nil)
    end

    def each_workspace_file(directory, state)
      pending = [[directory, ""]]
      until pending.empty?
        absolute, relative = pending.pop
        begin
          stat = File.lstat(absolute)
          next if stat.symlink?

          if stat.directory?
            entries = []
            # Bound enumeration as well as file reads: Dir.children.sort would
            # allocate an entire large directory before checking the limit.
            Dir.each_child(absolute) do |entry|
              next if HIDDEN_DIRECTORIES.include?(entry)

              if state["scanned_entries"] >= MAX_SCAN_ENTRIES
                state["scan_truncated"] = true
                break
              end
              state["scanned_entries"] += 1
              entries << entry
            end
            entries.sort.reverse_each do |entry|
              pending << [File.join(absolute, entry), relative.empty? ? entry : relative + "/" + entry]
            end
          elsif stat.file?
            yield absolute, relative
          end
        rescue SystemCallError
          state["skipped_files"] += 1
        end
      end
    end

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

      content = (File.binread(path, MAX_FILE_BYTES + 1) || +"").force_encoding(Encoding::UTF_8)
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
